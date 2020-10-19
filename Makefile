# We want to launch/build docker containers as our own UID, so we collect that from the environment
UID=$(shell id -u)
export UID

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(dir $(mkfile_path))

up: storage logs/nginx logs/pkgserver /etc/logrotate.d/pkgserver enable-docker
	docker-compose up --build --remove-orphans -d
	# fix some permissions issues
	docker-compose exec --user root pkgserver1 /bin/bash -c "chown ${UID}:root /app/storage/temp"
	docker-compose exec --user root pkgserver2 /bin/bash -c "chown ${UID}:root /app/storage/temp"

# Automatically enable docker on restart
enable-docker:
	-[ -n $(shell which systemctl 2>/dev/null) ] && sudo systemctl enable docker

storage:
	mkdir -p $@
logs/nginx:
	mkdir -p $@
	chmod 755 $@
logs/pkgserver:
	mkdir -p $@
	chmod 755 $@

/etc/logrotate.d/pkgserver: logrotate.conf
	LOGDIR=$(current_dir)logs SOURCEDIR=$(current_dir) envsubst < $< | sudo tee $@ >/dev/null

logs:
	tail -f logs/nginx/*.log logs/pkgserver/*.log

reload:
	sudo kill -HUP $$(pgrep -f 'nginx: master')

down:
	docker-compose down --remove-orphans

destroy:
	docker-compose down -v --remove-orphans

.PHONY: logs log_post_rotate down destroy
