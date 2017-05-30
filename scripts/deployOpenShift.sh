#!/bin/bash

echo $(date) " - Starting Script"

set -e

SUDOUSER=$1
PASSWORD="$2"
PRIVATEKEY=$3
MASTER=$4
MASTERPUBLICIPHOSTNAME=$5
MASTERPUBLICIPADDRESS=$6
INFRA=$7
NODE=$8
NODECOUNT=$9
INFRACOUNT=${10}
MASTERCOUNT=${11}
ROUTING=${12}
REGISTRYSA=${13}
ACCOUNTKEY="${14}"
METRICS=${15}
LOGGING=${16}
TENANTID=${17}
SUBSCRIPTIONID=${18}
AADCLIENTID=${19}
AADCLIENTSECRET="${20}"
RESOURCEGROUP=${21}
LOCATION=${22}
STORAGEACCOUNT1=${23}
STORAGEACCOUNT2=${24}
SAKEY1=${25}
SAKEY2=${26}
COCKPIT=${27}

BASTION=$(hostname)

MASTERLOOP=$((MASTERCOUNT - 1))
INFRALOOP=$((INFRACOUNT - 1))
NODELOOP=$((NODECOUNT - 1))

# Create Container in PV Storage Accounts
echo $(date) " - Creating container in PV Storage Accounts"

azure telemetry --disable
azure login --service-principal -u $AADCLIENTID -p $AADCLIENTSECRET --tenant $TENANTID

azure storage container create -a $STORAGEACCOUNT1 -k $SAKEY1 --container vhds
azure storage container create -a $STORAGEACCOUNT2 -k $SAKEY2 --container vhds

# Generate private keys for use by Ansible
echo $(date) " - Generating Private keys for use by Ansible for OpenShift Installation"

echo "Generating Private Keys"

runuser -l $SUDOUSER -c "echo \"$PRIVATEKEY\" > ~/.ssh/id_rsa"
runuser -l $SUDOUSER -c "chmod 600 ~/.ssh/id_rsa*"

echo "Configuring SSH ControlPath to use shorter path name"

sed -i -e "s/^# control_path = %(directory)s\/%%h-%%r/control_path = %(directory)s\/%%h-%%r/" /etc/ansible/ansible.cfg
sed -i -e "s/^#host_key_checking = False/host_key_checking = False/" /etc/ansible/ansible.cfg
sed -i -e "s/^#pty=False/pty=False/" /etc/ansible/ansible.cfg

# Create Ansible Playbooks for Post Installation tasks
echo $(date) " - Create Ansible Playbooks for Post Installation tasks"

# Run on all masters - Create Inital OpenShift User on all Masters

cat > /home/${SUDOUSER}/addocpuser.yml <<EOF
---
- hosts: masters
  gather_facts: no
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Create OpenShift Users"
  tasks:
  - name: create directory
    file: path=/etc/origin/master state=directory
  - name: add initial OpenShift user
    shell: htpasswd -cb /etc/origin/master/htpasswd ${SUDOUSER} "${PASSWORD}"
EOF

# Run on only MASTER-0 - Make initial OpenShift User a Cluster Admin

cat > /home/${SUDOUSER}/assignclusteradminrights.yml <<EOF
---
- hosts: master0
  gather_facts: no
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Make user cluster admin"
  tasks:
  - name: make OpenShift user cluster admin
    shell: oadm policy add-cluster-role-to-user cluster-admin $SUDOUSER --config=/etc/origin/master/admin.kubeconfig
EOF

# Run on all nodes - Set Root password on all nodes

cat > /home/${SUDOUSER}/assignrootpassword.yml <<EOF
---
- hosts: nodes
  gather_facts: no
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Set password for Cockpit"
  tasks:
  - name: configure Cockpit password
    shell: echo "${PASSWORD}"|passwd root --stdin
EOF

# Run on MASTER-0 node - configure registry to use Azure Storage

cat > /home/${SUDOUSER}/dockerregistry.yml <<EOF
---
- hosts: master0
  gather_facts: no
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Set registry to use Azure Storage"
  tasks:
  - name: Configure docker-registry to use Azure Storage
    shell: oc env dc docker-registry -e REGISTRY_STORAGE=azure -e REGISTRY_STORAGE_AZURE_ACCOUNTNAME=$REGISTRYSA -e REGISTRY_STORAGE_AZURE_ACCOUNTKEY=$ACCOUNTKEY -e REGISTRY_STORAGE_AZURE_CONTAINER=registry
EOF

# Run on MASTER-0 node - configure Storage Class

cat > /home/${SUDOUSER}/configurestorageclass.yml <<EOF
---
- hosts: master0
  gather_facts: no
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Create Storage Class"
  tasks:
  - name: Create Storage Class with StorageAccountPV1
    shell: oc create -f /home/${SUDOUSER}/scgeneric1.yml
  - name: Create Storage Class with StorageAccountPV2
    shell: oc create -f /home/${SUDOUSER}/scgeneric2.yml
EOF

# Create Playbook to reboot all nodes as last step to fix stuck nodes issue

cat > /home/${SUDOUSER}/rebootnodes.yml <<EOF
- hosts: nodes
  gather_facts: no
  become_user: root
  become: yes
  become_method: sudo
  tasks:
  - name: Reboot the server to finalize stuck node fix
    shell: systemd-run --on-active=10 /usr/bin/systemctl reboot
    async: 0
    poll: 0 
  - name: Wait for the server to reboot
    local_action: wait_for host="{{ansible_host}}" delay=120 state=started port=22 connect_timeout=60 timeout=240
EOF

# Create vars.yml file for use by setup-azure-config.yml playbook

cat > /home/${SUDOUSER}/vars.yml <<EOF
g_tenantId: $TENANTID
g_subscriptionId: $SUBSCRIPTIONID
g_aadClientId: $AADCLIENTID
g_aadClientSecret: $AADCLIENTSECRET
g_resourceGroup: $RESOURCEGROUP
g_location: $LOCATION
EOF

# Create Azure Cloud Provider configuration Playbook for Master Config

if [ $MASTERCOUNT -eq 1 ]
then

cat > /home/${SUDOUSER}/setup-azure-master.yml <<EOF
#!/usr/bin/ansible-playbook 
- hosts: masters
  gather_facts: no
  serial: 1
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    master_conf: /etc/origin/master/master-config.yaml
  handlers:
  - name: restart atomic-openshift-master
    systemd:
      state: restarted
      name: atomic-openshift-master

  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"

  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
        {
          "aadClientID" : "{{ g_aadClientId }}",
          "aadClientSecret" : "{{ g_aadClientSecret }}",
          "subscriptionID" : "{{ g_subscriptionId }}",
          "tenantID" : "{{ g_tenantId }}",
          "resourceGroup": "{{ g_resourceGroup }}",
        } 
    notify:
    - restart atomic-openshift-master

  - name: insert the azure disk config into the master
    modify_yaml:
      dest: "{{ master_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubernetesMasterConfig.apiServerArguments.cloud-config
      value:
      - "{{ azure_conf }}"

    - key: kubernetesMasterConfig.apiServerArguments.cloud-provider
      value:
      - azure

    - key: kubernetesMasterConfig.controllerArguments.cloud-config
      value:
      - "{{ azure_conf }}"

    - key: kubernetesMasterConfig.controllerArguments.cloud-provider
      value:
      - azure
    notify:
    - restart atomic-openshift-master
EOF

else

cat > /home/${SUDOUSER}/setup-azure-master.yml <<EOF
#!/usr/bin/ansible-playbook 
- hosts: masters
  gather_facts: no
  serial: 1
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    master_conf: /etc/origin/master/master-config.yaml
  handlers:
  - name: restart atomic-openshift-master-api
    systemd:
      state: restarted
      name: atomic-openshift-master-api

  - name: restart atomic-openshift-master-controllers
    systemd:
      state: restarted
      name: atomic-openshift-master-controllers

  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"

  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
        {
          "aadClientID" : "{{ g_aadClientId }}",
          "aadClientSecret" : "{{ g_aadClientSecret }}",
          "subscriptionID" : "{{ g_subscriptionId }}",
          "tenantID" : "{{ g_tenantId }}",
          "resourceGroup": "{{ g_resourceGroup }}",
        } 
    notify:
    - restart atomic-openshift-master-api
    - restart atomic-openshift-master-controllers

  - name: insert the azure disk config into the master
    modify_yaml:
      dest: "{{ master_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubernetesMasterConfig.apiServerArguments.cloud-config
      value:
      - "{{ azure_conf }}"

    - key: kubernetesMasterConfig.apiServerArguments.cloud-provider
      value:
      - azure

    - key: kubernetesMasterConfig.controllerArguments.cloud-config
      value:
      - "{{ azure_conf }}"

    - key: kubernetesMasterConfig.controllerArguments.cloud-provider
      value:
      - azure
    notify:
    - restart atomic-openshift-master-api
    - restart atomic-openshift-master-controllers
EOF

fi

# Create Azure Cloud Provider configuration Playbook for Node Config

cat > /home/${SUDOUSER}/setup-azure-node.yml <<EOF
#!/usr/bin/ansible-playbook 
- hosts: all
  serial: 1
  gather_facts: no
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    node_conf: /etc/origin/node/node-config.yaml
  handlers:
  - name: restart atomic-openshift-node
    systemd:
      state: restarted
      name: atomic-openshift-node
  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"

  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
        {
          "aadClientID" : "{{ g_aadClientId }}",
          "aadClientSecret" : "{{ g_aadClientSecret }}",
          "subscriptionID" : "{{ g_subscriptionId }}",
          "tenantID" : "{{ g_tenantId }}",
          "resourceGroup": "{{ g_resourceGroup }}",
        } 
    notify:
    - restart atomic-openshift-node
  - name: insert the azure disk config into the node
    modify_yaml:
      dest: "{{ node_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubeletArguments.cloud-config
      value:
      - "{{ azure_conf }}"

    - key: kubeletArguments.cloud-provider
      value:
      - azure
    notify:
    - restart atomic-openshift-node
  - name: delete the node so it can recreate itself
    command: oc delete node {{inventory_hostname}}
    delegate_to: ${BASTION}
  - name: sleep to let node come back to life
    pause:
       minutes: 1
EOF

# Create Ansible Hosts File
echo $(date) " - Create Ansible Hosts file"

if [ $MASTERCOUNT -eq 1 ]
then

cat > /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes
master0
new_nodes

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=true
deployment_type=openshift-enterprise
openshift_release=v3.5
docker_udev_workaround=True
openshift_use_dnsmasq=false
openshift_master_default_subdomain=$ROUTING
openshift_override_hostname_check=true
osm_use_cockpit=${COCKPIT}
os_sdn_network_plugin_name='redhat/openshift-ovs-multitenant'
console_port=443
openshift_cloudprovider_kind=azure
osm_default_node_selector='type=app'

# default selectors for router and registry services
openshift_router_selector='type=infra'
openshift_registry_selector='type=infra'

openshift_master_cluster_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_vip=$MASTERPUBLICIPADDRESS

# Enable HTPasswdPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# Setup metrics
openshift_hosted_metrics_deploy=$METRICS
# As of this writing, there's a bug in the metrics deployment.
# You'll see the metrics failing to deploy 59 times, it will, though, succeed the 60'th time.
openshift_metrics_cassandra_storage_type=dynamic
openshift_hosted_metrics_public_url=https://metrics.$ROUTING/hawkular/metrics

# Setup logging
openshift_hosted_logging_deploy=$LOGGING
openshift_hosted_logging_storage_kind=dynamic
openshift_master_logging_public_url=https://kibana.$ROUTING

# host group for masters
[masters]
$MASTER-0

[master0]
$MASTER-0

# host group for nodes
[nodes]
$MASTER-0 openshift_node_labels="{'type': 'master', 'zone': 'default'}" openshift_hostname=$MASTER-0
EOF

# Loop to add Infra Nodes

for (( c=0; c<$INFRACOUNT; c++ ))
do
  echo "$INFRA-$c openshift_node_labels=\"{'type': 'infra', 'zone': 'default'}\" openshift_hostname=$INFRA-$c" >> /etc/ansible/hosts
done

# Loop to add Nodes

for (( c=0; c<$NODECOUNT; c++ ))
do
  echo "$NODE-$c openshift_node_labels=\"{'type': 'app', 'zone': 'default'}\" openshift_hostname=$NODE-$c" >> /etc/ansible/hosts
done

# Create new_nodes group

cat >> /etc/ansible/hosts <<EOF

# host group for adding new nodes
[new_nodes]
EOF

else

cat > /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes
etcd
master0
new_nodes

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=true
deployment_type=openshift-enterprise
openshift_release=v3.5
docker_udev_workaround=True
openshift_use_dnsmasq=false
openshift_master_default_subdomain=$ROUTING
openshift_override_hostname_check=true
osm_use_cockpit=${COCKPIT}
os_sdn_network_plugin_name='redhat/openshift-ovs-multitenant'
console_port=443
openshift_cloudprovider_kind=azure
osm_default_node_selector='type=app'

# default selectors for router and registry services
openshift_router_selector='type=infra'
openshift_registry_selector='type=infra'

openshift_master_cluster_method=native
openshift_master_cluster_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_vip=$MASTERPUBLICIPADDRESS

# Enable HTPasswdPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# Setup metrics
openshift_hosted_metrics_deploy=$METRICS
# As of this writing, there's a bug in the metrics deployment.
# You'll see the metrics failing to deploy 59 times, it will, though, succeed the 60'th time.
openshift_metrics_cassandra_storage_type=dynamic
#openshift_hosted_metrics_public_url=https://metrics.$ROUTING/hawkular/metrics

# Setup logging
openshift_hosted_logging_deploy=$LOGGING
openshift_hosted_logging_storage_kind=dynamic
openshift_master_logging_public_url=https://kibana.$ROUTING

# host group for masters
[masters]
$MASTER-[0:${MASTERLOOP}]

# host group for etcd
[etcd]
$MASTER-[0:${MASTERLOOP}] 

[master0]
$MASTER-0

# host group for nodes
[nodes]
EOF

# Loop to add Masters

for (( c=0; c<$MASTERCOUNT; c++ ))
do
  echo "$MASTER-$c openshift_node_labels=\"{'type': 'master', 'zone': 'default'}\" openshift_hostname=$MASTER-$c" >> /etc/ansible/hosts
done

# Loop to add Infra Nodes

for (( c=0; c<$INFRACOUNT; c++ ))
do
  echo "$INFRA-$c openshift_node_labels=\"{'type': 'infra', 'zone': 'default'}\" openshift_hostname=$INFRA-$c" >> /etc/ansible/hosts
done

# Loop to add Nodes

for (( c=0; c<$NODECOUNT; c++ ))
do
  echo "$NODE-$c openshift_node_labels=\"{'type': 'app', 'zone': 'default'}\" openshift_hostname=$NODE-$c" >> /etc/ansible/hosts
done

# Create new_nodes group

cat >> /etc/ansible/hosts <<EOF

# host group for adding new nodes
[new_nodes]
EOF

fi

# Initiating installation of OpenShift Container Platform using Ansible Playbook
echo $(date) " - Installing OpenShift Container Platform via Ansible Playbook"

runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/byo/config.yml"

echo $(date) " - Modifying sudoers"

sed -i -e "s/Defaults    requiretty/# Defaults    requiretty/" /etc/sudoers
sed -i -e '/Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"/aDefaults    env_keep += "PATH"' /etc/sudoers

# Deploying Registry
echo $(date) "- Registry automatically deployed to infra nodes"

# Deploying Router
echo $(date) "- Router automaticaly deployed to infra nodes"

echo $(date) "- Re-enabling requiretty"

sed -i -e "s/# Defaults    requiretty/Defaults    requiretty/" /etc/sudoers

# Install OpenShift Atomic Client

cd /root
mkdir .kube
runuser -l ${SUDOUSER} -c "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SUDOUSER}@${MASTER}-0:~/.kube/config /tmp/kube-config"
cp /tmp/kube-config /root/.kube/config
mkdir /home/${SUDOUSER}/.kube
cp /tmp/kube-config /home/${SUDOUSER}/.kube/config
chown --recursive ${SUDOUSER} /home/${SUDOUSER}/.kube
rm -f /tmp/kube-config
yum -y install atomic-openshift-clients 

# Adding user to OpenShift authentication file
echo $(date) "- Adding OpenShift user"

runuser -l $SUDOUSER -c "ansible-playbook ~/addocpuser.yml"

# Assigning cluster admin rights to OpenShift user
echo $(date) "- Assigning cluster admin rights to user"

runuser -l $SUDOUSER -c "ansible-playbook ~/assignclusteradminrights.yml"

if [[ $COCKPIT == "true" ]]
then

# Setting password for root if Cockpit is enabled
echo $(date) "- Assigning password for root, which is used to login to Cockpit"

runuser -l $SUDOUSER -c "ansible-playbook ~/assignrootpassword.yml"
fi

# Create Storage Classes
echo $(date) "- Creating Storage Classes"

runuser -l $SUDOUSER -c "ansible-playbook ~/configurestorageclass.yml"

# Configure Docker Registry to use Azure Storage Account
echo $(date) "- Configuring Docker Registry to use Azure Storage Account"

runuser -l $SUDOUSER -c "ansible-playbook ~/dockerregistry.yml"

echo $(date) "- Sleep for 120"

sleep 120

# Execute setup-azure-master and setup-azure-node playbooks to configure Azure Cloud Provider
echo $(date) "- Configuring OpenShift Cloud Provider to be Azure"

runuser -l $SUDOUSER -c "ansible-playbook ~/setup-azure-master.yml"
runuser -l $SUDOUSER -c "ansible-playbook ~/setup-azure-node.yml"

# Delete postinstall.yml file
echo $(date) "- Deleting unecessary files"

rm /home/${SUDOUSER}/addocpuser.yml
rm /home/${SUDOUSER}/assignclusteradminrights.yml
rm /home/${SUDOUSER}/assignrootpassword.yml
rm /home/${SUDOUSER}/dockerregistry.yml

echo $(date) " - Script complete"
