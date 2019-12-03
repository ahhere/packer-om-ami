#!/usr/bin/env bash
#
# Bash script for provisioning the MongoDB instances

function checkInstall(){
  if [[ -f /opt/mongodb/mms/bin/mongodb-mms ]];then
    echo 0
  else
    echo 1
  fi
}

function osConfig(){
  export HOST_IP_ADDR=`ifconfig  | grep 'inet addr:'| grep -v '127.0.0.1' | cut -d: -f2 | awk '{ print $1}' | tail -1`
  export HOST_FQDN=`hostname -f`
  export HOST_NAME=`hostname | cut -d. -f 1 | tr '[:upper:]' '[:lower:]'`
  export URL="http://localhost:8080"
  echo "Configuring /etc/hosts ..."
  echo "127.0.0.1 localhost localhost.localdomain localhost4 localhost4.localdomain4" > /etc/hosts
  echo "::1       localhost localhost.localdomain localhost6 localhost6.localdomain6" >> /etc/hosts
  echo "$HOST_IP_ADDR    $HOST_FQDN $HOST_NAME" >> /etc/hosts
  # disable THP
  echo "Disabling THP"
  echo -e "never" > /sys/kernel/mm/transparent_hugepage/enabled
  echo -e "never" > /sys/kernel/mm/transparent_hugepage/defrag
   # ulimits because they will cause you hassle
   ulimit -q 819200
   ulimit -n 21000
   ulimit -t unlimited
}

function installMongod(){
  if [[ ! -d /data/appdb ]];then
    echo "Install MongoDB Enterprise"
    sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 0C49F3730359A14518585931BC711F9BA15703C6
    echo "deb [ arch=amd64,arm64,ppc64el,s390x ] http://repo.mongodb.com/apt/ubuntu xenial/mongodb-enterprise/4.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-enterprise.list
    sudo apt-get update
    sudo apt-get install -y --allow-unauthenticated mongodb-enterprise

    echo "Creating appDB directory"
    sudo mkdir -p /data/appdb
    sudo chown -R mongodb:mongodb /data
    echo "Creating backup directory"
    sudo mkdir -p /data/backup
    sudo chown mongodb:mongodb /data/backup
  fi

}

function startMongod(){
  echo "Starting MongoDB"
  echo ""
  echo "Starting appDB" 
  sudo -u mongodb mongod --port 27017 --dbpath /data/appdb \
  --logpath /data/appdb/mongodb.log \
  --wiredTigerCacheSizeGB 1 --fork

  echo "Starting blockstore"
  sudo -u mongodb mongod --port 27018 --dbpath /data/backup \
  --logpath /data/backup/mongodb.log \
  --wiredTigerCacheSizeGB 1 --fork

}

function installOpsManager(){
  cd /shared
  echo "Downloading mongodb-mms.deb"
  curl -s -o /shared/mongodb-mms.deb https://s3.amazonaws.com/mongodb-mms-build-onprem/c756e6a29c08249e4b32413c47348dbe2c8b34a3/mongodb-mms_4.0.12.50517.20190605T1533Z-1_x86_64.deb
  echo "Installing Ops Manager"
  sudo dpkg -i /shared/mongodb-mms.deb
  echo "Creating HEAD directory"
  sudo mkdir -p /backups/HEAD
  sudo chown -R mongodb-mms:mongodb-mms /backups
}

function buildConf(){
  echo "Building bare minimum 'conf-mms.properties'"
  cat <<eof >> /opt/mongodb/mms/conf/conf-mms.properties
mms.ignoreInitialUiSetup=true
mongo.mongoUri=mongodb://localhost:27017
mms.centralUrl=$HOST_FQDN:8080
mms.fromEmailAddr=example@$HOST_NAME
mms.replyToEmailAddr=example@$HOST_NAME
mms.adminEmailAddr=example@$HOST_NAME
mms.mail.transport=smtp
mms.mail.hostname=$HOST_NAME
mms.mail.port=25
mms.userSvcClass=com.xgen.svc.mms.svc.user.UserSvcDb

eof
}


function startMms(){
  sudo service mongodb-mms start
}

function createFirstUser(){
  echo -n "Creating the first admin user."
  curl -s $URL
  ret=$?
  while [[ $ret -ne 0 ]];do
    echo -n "."
    sleep 5
    curl -s $URL
    ret=$?
  done
  echo "."
  curl --digest \
    --header "Accept: application/json" \
    --header "Content-Type: application/json" \
    --include \
    --request POST "$URL/api/public/v1.0/unauth/users?pretty=true&whitelist=$HOST_IP_ADDR" \
    --data '
      {
        "username": "ops.manager@localhost",
        "password": "Passw0rd.",
        "firstName": "Ops",
        "lastName": "Manager"
      }'
}
function updateRepo(){
  echo "Install MongoDB Enterprise Repository"
  echo "deb http://repo.mongodb.com/apt/ubuntu "$(lsb_release -sc)"/mongodb-enterprise/3.3 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-enterprise.list
  sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 0C49F3730359A14518585931BC711F9BA15703C6
  echo "Update Repositoryies"
  sudo apt-get update -y
  echo "Installing MongoDB Enterprise Dependencies"
  sudo apt-get install -y libgssapi-krb5-2 libsasl2-2 libssl1.0.0 libstdc++6 snmp
}

if [[ `checkInstall` -eq 0 ]]
  then
    echo "Ops Manager is already installed, exiting"
    exit 0
  else
    echo "Installing and configuring MongoDB Ops Manager"
    osConfig
    updateRepo
    installMongod
    installOpsManager
    buildConf
    startMongod
    startMms
    createFirstUser
    echo "DONE"
fi
