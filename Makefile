.PHONY: send-release-event deploy tags cleanup zuul-secrets move-stable

ANSIBLE_PYTHON ?= $(shell command -v /usr/bin/python3 2> /dev/null || echo /usr/bin/python2)
CONT_HOME := /opt/app-root/src
AP := ansible-playbook -vv -c local -i localhost, -e ansible_python_interpreter=$(ANSIBLE_PYTHON)
# "By default, Ansible runs as if --tags all had been specified."
# https://docs.ansible.com/ansible/latest/user_guide/playbooks_tags.html#special-tags
TAGS ?= all
VAGRANT_SSH_PORT = "$(shell cd containers && vagrant ssh-config | awk '/Port/{print $$2}')"
VAGRANT_SSH_USER = "$(shell cd containers && vagrant ssh-config | awk '/User/{print $$2}')"
VAGRANT_SSH_GUEST = "$(shell cd containers && vagrant ssh-config | awk '/HostName/{print $$2}')"
VAGRANT_SSH_IDENTITY_FILE = "$(shell cd containers && vagrant ssh-config | awk '/IdentityFile/{print $$2}')"
VAGRANT_SSH_CONFIG = $(shell cd containers && vagrant ssh-config | awk 'NR>1 {print " -o "$$1"="$$2}')
VAGRANT_SHARED_DIR = "/vagrant"

CENTOS_VAGRANT_BOX = CentOS-Stream-Vagrant-8-latest.x86_64.vagrant-libvirt.box
CENTOS_VAGRANT_URL = https://cloud.centos.org/centos/8-stream/x86_64/images/$(CENTOS_VAGRANT_BOX)

CRC_PULL_SECRET ?= "$(shell cat secrets/openshift-local-pull-secret.yml)"

ifneq "$(shell whoami)" "root"
	ASK_PASS ?= --ask-become-pass
endif

# Only for Packit team members with access to Bitwarden vault
# if not working prepend OPENSSL_CONF=/dev/null to script invocation
download-secrets:
	./scripts/download_secrets.sh

# Mimic what we do during deployment when we render secret files
# from their templates before we create k8s secrets from them.
render-secrets-from-templates:
	./scripts/render_secrets_from_templates.sh

# If you're sure you want to skip the secrets downloading,
# because for example you just did it and you don't want to wait for it again
# just set SKIP_SECRETS_SYNC or SSS to any value.
deploy: download-secrets
	$(AP) playbooks/deploy.yml --tags $(TAGS)

tags:
	$(AP) playbooks/deploy.yml --list-tags

cleanup:
	$(AP) playbooks/cleanup.yml

# Import newer images from registry.
# Causes re-deployment of components with newer image available.
import-images:
	$(AP) playbooks/import-images.yml

zuul-secrets:
	$(AP) playbooks/zuul-secrets.yml

generate-local-secrets:
	$(AP) $(ASK_PASS) playbooks/generate-local-secrets.yml

# Check whether everything has been deployed OK with 'make deploy'
check:
	$(AP) playbooks/check.yml

move-stable:
	[[ -d move_stable_repositories ]] || scripts/move_stable.py init
	scripts/move_stable.py move-all

oc-cluster-create:
# vagrant pointer is broken...
	[[ -f $(CENTOS_VAGRANT_BOX) ]] || wget $(CENTOS_VAGRANT_URL)
	cd containers && vagrant up

oc-cluster-destroy:
	cd containers && vagrant destroy

oc-cluster-up:
	cd containers && vagrant up
	cd containers && vagrant ssh -c "cd $(VAGRANT_SHARED_DIR) && $(AP) --extra-vars user=vagrant playbooks/oc-cluster-run.yml"

oc-cluster-down:
	cd containers && vagrant halt

oc-cluster-ssh: oc-cluster-up
	ssh $(VAGRANT_SSH_CONFIG) localhost

test-deploy:
# to be run inside VM where the oc cluster && tmt is running! Call make tmt-vagrant-tests instead from outside the vagrant machine.
# SHARED_DIR could be /vagrant or /home/tmt/deployment, it depends on the VM where tmt is being run
# look inside deployment.fmf to find out the value of SHARED_DIR
	DEPLOYMENT=dev $(AP) playbooks/generate-local-secrets.yml
	DEPLOYMENT=dev $(AP) -e '{"user": $(USER), "src_dir": $(SHARED_DIR)}' playbooks/test_deploy_setup.yml
	cd $(SHARED_DIR); DEPLOYMENT=dev $(AP) -e '{"container_engine": "podman", "registry": "default-route-openshift-image-registry.apps-crc.testing", "registry_user": "kubeadmin", "user": $(USER), "src_dir": $(SHARED_DIR)}' playbooks/test_deploy.yml

# Openshift Local pull_secret must exist locally
# or you can also define the CRC_PULL_SECRET var
check-pull-secret:
	if [ ! -f secrets/openshift-local-pull-secret.yml ] && [ ! -n "$(CRC_PULL_SECRET)" ]; then echo "no pull secret available create secrets/openshift-local-pull-secret.yml file or set CRC_PULL_SECRET variable"; exit 1; else echo "pull secret found"; fi

# Execute tmt deployment test on a vagrant virtual machine
# The virtual machine has to be already up and running,
# using the target oc-cluster-up
tmt-vagrant-test: check-pull-secret
	tmt run --all provision --how connect --user vagrant --guest $(VAGRANT_SSH_GUEST) --port $(VAGRANT_SSH_PORT) --key $(VAGRANT_SSH_IDENTITY_FILE) plan --name deployment/vagrant

# Execute tmt deployment test on a local virtual machine provisioned by tmt
#
# tmt local provisioned virtual machine have by default 2 cpu cores
# you need to change tmt defaults to be able to run this test locally
# change DEFAULT_CPU_COUNT in tmt/steps/provision/testcloud.py to 6
#
# For running this same test remotely, using testing farm, we need the
# github action, there are no other ways (at the moment) to deal with
# the secrets (in our case the pull_request Openshift Local secret).
# For this reason the deployment/remote plan is not called by this file
# but is called from the testing farm github action configured in this PR
#
# Useful tmt/virsh commands to debug this test are listed below
# tmt run --id deployment --until execute
# tmt run --id deployment prepare --force
# tmt run --id deployment login --step prepare:start
# tmt run --id deployment execute --force
# tmt run --id deployment login --step execute:start
# tmt run --id deployment finish
# tmt clean runs
# tmt clean guests
# virsh list --all
tmt-local-test: check-pull-secret
	tmt run --id deployment plans --name deployment/local
