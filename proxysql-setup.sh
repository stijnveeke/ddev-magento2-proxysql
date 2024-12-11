#!/bin/bash

echo "Starting setup for database containers..."
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <sitename>"
    exit 1
fi

SITENAME=$1

check_containers() {
  for container in "ddev-$SITENAME-db" "ddev-$SITENAME-replica-1" "ddev-$SITENAME-replica-2" "ddev-$SITENAME-replica-canary"; do
    if ! docker ps -q -f name="$container" > /dev/null; then
      echo "Container $container is not running."
      return 1
    fi
  done
  return 0
}

check_db_connections() {
  local container=$1
  args=(-h "127.0.0.1" -u "root" -proot --silent)

  if docker exec -i "$container" command -v mysqladmin > /dev/null; then
    if docker exec -i "$container" mysqladmin "${args[@]}" ping > /dev/null; then
      return 0
    fi
  else
    select=$(echo 'SELECT 1' | docker exec -i "$container" mysql "${args[@]}")
    if [ "$select" = "1" ]; then
      return 0
    fi
  fi
  return 1
}

retry_connection() {
  local container=$1
  local max_retries=5
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    if check_db_connections "$container"; then
      return 0
    fi
    echo "Attempt $attempt failed for $container. Retrying in 2 seconds..."
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "Max retries reached for $container. Exiting."
  return 1
}

if ! check_containers; then
  echo "One or more containers not found, exiting."
  exit 1
fi

if ! retry_connection "ddev-$SITENAME-db"; then exit 1; fi
if ! retry_connection "ddev-$SITENAME-replica-1"; then exit 1; fi
if ! retry_connection "ddev-$SITENAME-replica-2"; then exit 1; fi
if ! retry_connection "ddev-$SITENAME-replica-canary"; then exit 1; fi

echo "All database containers are running and accepting connections."
echo "Setting up db users for $SITENAME..."

create_monitor_user() {
  local container=$1

  docker exec -i "$container" mysql -u root -proot -e "
    CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'monitor';
    GRANT SELECT ON sys.* TO 'monitor'@'%';
    FLUSH PRIVILEGES;
  "
}

echo "Creating monitor users for db and replicas..."
create_monitor_user "ddev-$SITENAME-db"
create_monitor_user "ddev-$SITENAME-replica-1"
create_monitor_user "ddev-$SITENAME-replica-2"
create_monitor_user "ddev-$SITENAME-replica-canary"
echo "Monitor users created."


create_db_users_for_replicas() {
  local container=$1

  docker exec -i "$container" mysql -u root -proot -e "
    CREATE USER IF NOT EXISTS 'db'@'%' IDENTIFIED BY 'db';
    GRANT ALL PRIVILEGES ON db.* TO 'db'@'%';
    FLUSH PRIVILEGES;
  "
}

echo "Setting up DB users for $SITENAME..."
create_db_users_for_replicas "ddev-$SITENAME-replica-1"
create_db_users_for_replicas "ddev-$SITENAME-replica-2"
create_db_users_for_replicas "ddev-$SITENAME-replica-canary"
echo "DB users created."

echo "Setting up canary users for $SITENAME..."
docker exec -i "ddev-$SITENAME-replica-canary" mysql -u root -proot -e "
  CREATE USER IF NOT EXISTS 'canary'@'%' IDENTIFIED BY 'canary';
  GRANT ALL PRIVILEGES ON db.* TO 'canary'@'%';
  FLUSH PRIVILEGES;
"
docker exec -i "ddev-$SITENAME-db" mysql -u root -proot -e "
  CREATE USER IF NOT EXISTS 'canary'@'%' IDENTIFIED BY 'canary';
  GRANT ALL PRIVILEGES ON db.* TO 'canary'@'%';
  FLUSH PRIVILEGES;
";
echo "Canary users created."

