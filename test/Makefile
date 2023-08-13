
DISTROS=$$(ls ../docker/docker-files/templates/)

all:
	for d in $(DISTROS); do\
	    (cd ../docker; ./docker-build-gcs.sh $$d) 2>&1 | tee $$d.log;\
	done

%:
	(cd ../docker; ./docker-build-gcs.sh $@) 2>&1 | tee $@.log;\

clean:
	rm -f *log

clobber: clean
	(cd ../docker/docker-files; make clobber-images)

.SILENT: clobber
