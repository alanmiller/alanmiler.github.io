#!/bin/bash

# ------------------------------------
# variables: loads ../config/setup.cfg
# ------------------------------------
CONFIG=`/usr/bin/dirname $0`"/../config/setup.cfg"
[[ ! -f ${CONFIG} ]] && exit 1
printf "Loading settings from %s\n" ${CONFIG}
. ${CONFIG}

# ------------------------------------
# function
# ------------------------------------
createinstallprops() {
cat > ${PROPFILE} <<EOF
#
# Sample properties file to set up OpenDJ directory server
#
hostname                        =localhost
ldapPort                        =389
generateSelfSignedCertificate   =true
enableStartTLS                  =true
ldapsPort                       =636
jmxPort                         =689
adminConnectorPort              =4444
rootUserDN                      =cn=Directory Manager
rootUserPassword                =0pendj
baseDN                          =dc=${COMPANYNAME},dc=com
ldifFile                        =${PROPDIR}/opendj.ldif
#sampleData                     =2000
EOF
}

installds() {
  # zip file creates extra opendj dir so move everything a level up
  unzip -qq -d ${DEPLOYDIR} ${ZIPFILE}
  mv ${DEPLOYDIR}/opendj/* ${DEPLOYDIR}
  rm -rf ${DEPLOYDIR}/opendj


  if [ $? -eq 0 ] ; then
    if [ -r ${PROPFILE} ] ; then
      cd ${DEPLOYDIR}
      printf "Installing OpenDJ to %s\n" ${DEPLOYDIR}
      ${DEPLOYDIR}/setup --cli --propertiesFilePath ${PROPFILE}  --acceptLicense --no-prompt
    else
      echo "No properties file"
      exit
    fi
  else
    printf "failed to unzip %s\n" ${ZIPFILE}
    exit
  fi
}

config_ssl() {
  echo -n "Setting Blind Trust Manager ..."
  ${DSCONFIG} \
   set-trust-manager-provider-prop \
   --hostname ${HOSTNAME} \
   --port 4444 \
   --bindDN "cn=Directory Manager" \
   --bindPassword ${BINDPASS} \
   --provider-name "Blind Trust" \
   --set enabled:true \
   --no-prompt \
   --trustAll
   echo  $?|sed -e 's/0/Okay/g' -e 's/1/NotOkay/g'
  
  echo -n "Setting HTTP Connection Handler ..."
  ${DSCONFIG} \
   set-connection-handler-prop \
   --hostname ${HOSTNAME} \
   --port 4444 \
   --bindDN "cn=Directory Manager" \
   --bindPassword ${BINDPASS} \
   --handler-name "HTTP Connection Handler" \
   --set listen-port:8443 \
   --set enabled:true \
   --set use-ssl:true \
   --set key-manager-provider:JKS \
   --set trust-manager-provider:"Blind Trust" \
   --no-prompt \
   --trustAll
   echo  $?|sed -e 's/0/Okay/g' -e 's/1/NotOkay/g'
}
configds() {
  echo -n "Setting LDIF Connection Handler ..."
  ${DSCONFIG} \
   set-connection-handler-prop \
   --hostname ${HOSTNAME} \
   --port 4444 \
   --bindDN "cn=Directory Manager" \
   --bindPassword ${BINDPASS} \
   --handler-name "LDIF Connection Handler" \
   --set enabled:true \
   --trustAll \
   --no-prompt
   echo  $?|sed -e 's/0/Okay/g' -e 's/1/NotOkay/g'

  echo -n "Setting File-Based HTTP Access Logger ..."
  mkdir ${DEPLOYDIR}/config/auto-process-ldif
  ${DSCONFIG} \
   set-log-publisher-prop \
   --hostname ${HOSTNAME} \
   --port 4444 \
   --bindDN "cn=Directory Manager" \
   --bindPassword ${BINDPASS} \
   --publisher-name "File-Based HTTP Access Logger" \
   --set enabled:true \
   --no-prompt \
   --trustAll
   echo  $?|sed -e 's/0/Okay/g' -e 's/1/NotOkay/g'

  echo -n "Setting AD PTA Policy ..."
  ${DSCONFIG} \
   create-password-policy \
   --port 4444 \
   --hostname ${HOSTNAME} \
   --bindDN "cn=Directory Manager" \
   --bindPassword ${BINDPASS} \
   --type ldap-pass-through \
   --policy-name "AD PTA Policy" \
   --set primary-remote-ldap-server:san-dcgc-01.san.ssnsgs.net:389 \
   --set mapped-attribute:cn \
   --set mapped-search-base-dn:"ou=US,ou=User Accounts,ou=SSN-Clients,dc=silverspringnet,dc=com" \
   --set mapped-search-bind-dn:"cn=ops hadoop,ou=ServiceAccounts,ou=SSN-Production,dc=silverspringnet,dc=com" \
   --set mapped-search-bind-password:"H@d00p123" \
   --set mapping-policy:mapped-search \
   --set use-ssl:false \
   --no-prompt \
   --trustAll
   echo  $?|sed -e 's/0/Okay/g' -e 's/1/NotOkay/g'

  cp ${HTTPCONF} ${DEPLOYDIR}/config/
}
mkdiradmin() {
  printf "Creating Directory Admin\n"
  cp ${PROPDIR}/diradmin-user.ldif ${DEPLOYDIR}/config/auto-process-ldif
  sleep 2
  cp ${PROPDIR}/diradmin-privileges.ldif ${DEPLOYDIR}/config/auto-process-ldif
}
exportservercert() {
  keytool \
   -export \
   -rfc \
   -alias server-cert \
   -keystore ${DEPLOYDIR}/config/keystore \
   -storepass `cat ${DEPLOYDIR}/config/keystore.pin` \
   -file ${PROPDIR}/server-cert.pem
}
dsstatus() {
  ${STATUS} \
   --bindDN "cn=Directory Manager" \
   --bindPassword ${BINDPASS} \
   --no-prompt \
   --trustAll
}
restartds() {
  ${STOPDS} --restart
}
stopds() {
  ${STOPDS}
}
clean() {
  stopds
  rm -rf ${DEPLOYDIR}
}
runtests() {
  printf "Create pass-through user: amiller\n"
  cp ${PROPDIR}/amiller.ldif ${DEPLOYDIR}/config/auto-process-ldif
  printf "Create local-auth user: hive (pw: hive)\n"
  cp ${PROPDIR}/hive.ldif ${DEPLOYDIR}/config/auto-process-ldif
  sleep 2
  printf "REST request for amiller (prompted for AD credentials)\n"
  CURL="https://${HOSTNAME}:8443/users"
  DJUSER="amiller"
  curl -s -u ${DJUSER} -k "${CURL}/${DJUSER}" |python -mjson.tool
  printf "REST request for hive user (enter password hive)\n"
  DJUSER="hive"
  curl -s -u ${DJUSER} -k "${CURL}/${DJUSER}" |python -mjson.tool
}
# ------------------------------------
# main
# ------------------------------------
# clean
createinstallprops
installds
exportservercert
dsstatus
configds
restartds
config_ssl
restartds
mkdiradmin
dsstatus

# runtests
