all: docker-files

ansible.64:
	echo ";; This is the 'tar zxf - | base64' of the ansible sub directory" > partials/ansible.64
	(cd ../../; tar zcf - --owner=root --group=root ansible | base64) >> partials/ansible.64

entrypoint.64:
	echo ";; This is the 'tar zxf - | base64' of entrypoint.sh" > partials/entrypoint.64
	(cd ../; tar zcf - entrypoint.sh | base64) >> partials/entrypoint.64

yum.64:
	echo ";; This is the 'tar zxf - | base64' of partials/yum/" > partials/yum.64
	(cd partials; tar zcf - --owner=root --group=root yum | base64) >> partials/yum.64


docker-files: ansible.64 entrypoint.64 yum.64
	bash -c '\
            declare -A partials;\
            \
	        for partial in  $$(ls partials/); do \
                    if [ -f partials/$$partial ]; then \
                        key=$$(echo $$partial | tr [:lower:] [:upper:] | tr . _);\
                        partials[$$key]=$$(cat partials/$$partial | grep -v \;\;);\
                    fi;\
                done;\
            \
            for template in $$(ls templates/); do \
                docker_file=$$(cat templates/$$template | grep -v \;\;);\
                \
                is_done=0;\
                while (( is_done == 0 )); do \
                    is_done=1;\
                    for partial in $${!partials[@]}; do \
                        echo "$$docker_file" | grep "\$$$$partial" > /dev/null;\
                        if [[ $$? == 0 ]]; then \
                            is_done=0;\
                            docker_file="$${docker_file//\$$$$partial/$${partials[$${partial}]}}";\
                        fi;\
                    done;\
                done;\
                echo "$$docker_file" > Dockerfile.$$template;\
            done'

clean:
	rm -f partials/ansible.64 partials/entrypoint.64 partials/yum.64
	bash -c '\
            for template in $$(ls templates/); do \
                rm -f Dockerfile.$$template;\
            done;'
	rm -fd empty

clobber-images:
	for image in $$(docker image ls --filter reference="globus/globus-connect-server" --format '{{.Repository}}:{{.Tag}}'); do \
	    docker rmi $$image; \
	done; \
	for repo in almalinux centos debian fedora opensuse/leap oraclelinux redhat/ubi8 redhat/ubi9 rockylinux ubuntu; do \
	    for image in $$(docker image ls --filter reference="$$repo" --format '{{.Repository}}:{{.Tag}}'); do \
	        docker rmi $$image; \
	    done; \
	done; \
	docker image prune -f;
	docker builder prune -f;

.SILENT:
