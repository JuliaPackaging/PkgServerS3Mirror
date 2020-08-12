# We want to launch/build docker containers as our own UID, so we collect that from the environment
UID=$(shell id -u)
export UID

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(dir $(mkfile_path))

up: storage logs/nginx logs/pkgserver /etc/logrotate.d/pkgserver enable-docker
	docker-compose up --build --remove-orphans -d

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

log_post_rotate_nginx:
	docker-compose exec frontend /bin/bash -c "killall -USR1 nginx"

down:
	docker-compose down --remove-orphans

destroy:
	docker-compose down -v --remove-orphans

.PHONY: logs log_post_rotate down destroy
