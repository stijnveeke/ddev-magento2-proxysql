setup() {
  set -eu -o pipefail
  export DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )/.."
  export TESTDIR=~/tmp/ddev-magento2-proxysql
  mkdir -p $TESTDIR
  export PROJNAME=ddev-magento2-proxysql
  export DDEV_NONINTERACTIVE=true
  ddev delete -Oy ${PROJNAME} >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  ddev config --project-name=${PROJNAME}
  ddev start -y >/dev/null
}

health_checks() {
  # Do something useful here that verifies the add-on
  # ddev exec "curl -s elasticsearch:9200" | grep "${PROJNAME}-elasticsearch"
  declare -A credentials_map
  credentials=$(mysql -u radmin -pradmin -h 127.0.0.1 -P6032 -e "select username, password, default_hostgroup from mysql_users;" | tail -n +2 | head -n 2)
  # Loop credentials to obtain login info for each hostgroup
  while read -r line; do
    username=$(echo $line | awk '{print $1}')
    password=$(echo $line | awk '{print $2}')
    hostgroup=$(echo $line | awk '{print $3}')
    if [ "${hostgroup}" == "2" ]; then
      credentials_map["regular"]="-u $username -p$password"
    elif [ "${hostgroup}" == "3" ]; then
      credentials_map["canary"]="-u $username -p$password"
    fi
  done <<< "${credentials}"

  credentials_map["remote_admin"]="-u radmin -pradmin"

  # Check if we can connect to the proxysql instance
  echo "${credentials_map[canary]}"
  echo "${credentials_map[regular]}"


  check_if_proxysql_setup "${credentials_map[remote_admin]}"
  check_if_db_accessible "${credentials_map[canary]}"
  check_if_db_accessible "${credentials_map[regular]}"
}

check_if_container_running() {
  container_name=${1:-${PROJNAME}}
  echo "Checking if container ${container_name} is running"
  echo $(docker ps)
  container_id=$(docker ps -qf name=$container_name)
  container_status=$(docker inspect --format='{{.State.Status}}' ${container_id} | grep running)
  [ "${container_status}" != "" ] && echo "Container is runnning" || (echo "Container is not running" && exit 1)
}

check_if_proxysql_setup() {
  check_if_container_running ${PROJNAME}
  check_if_container_running "ddev-${PROJNAME}-proxyweb"
  check_if_container_running "ddev-${PROJNAME}-replica-canary"
}

#TODO: Add test to check if the proxysql correctly redirects specific queries to the canary instance or the regular instance. For Example (core_config_data => canary, sales_order => regular)
#TODO: Add test to check if config is changed it redirects to the correct instance.
#TODO: Add test to check if upgrade command is executed correctly. (Do this be enabling/disabling some modules)

check_if_db_accessible() {
  credentials=${1}
  port=${2:-6033}
  mysql $1 -h127.0.0.1 -P$port -e "show databases;"
  [ $? -eq 0 ] && echo "Database is accessible" || (echo "Database is not accessible" && exit 1)
}

teardown() {
  set -eu -o pipefail
  cd ${TESTDIR} || ( printf "unable to cd to ${TESTDIR}\n" && exit 1 )
  ddev delete -Oy ${PROJNAME} >/dev/null 2>&1
  [ "${TESTDIR}" != "" ] && rm -rf ${TESTDIR}
}

@test "install from directory" {
  set -eu -o pipefail
  cd ${TESTDIR}
  echo "# ddev get ${DIR} with project ${PROJNAME} in ${TESTDIR} ($(pwd))" >&3
  ddev get stijnveeke/ddev-magento2-db-replication
  ddev get ${DIR}
  ddev restart
  health_checks
}

bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  cd ${TESTDIR} || ( printf "unable to cd to ${TESTDIR}\n" && exit 1 )
  echo "# ddev get ddev/ddev-addon-template with project ${PROJNAME} in ${TESTDIR} ($(pwd))" >&3
  ddev get stijnveeke/ddev-magento2-db-replication
  ddev get stijnveeke/ddev-magento2-proxysql
  ddev restart >/dev/null
  health_checks
}
