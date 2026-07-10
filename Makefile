.PHONY: setup verify chaos demo access teardown

setup:
	./setup.sh

verify:
	./verify.sh

chaos:
	./chaos/run-all.sh

demo:
	DEMO=1 ./chaos/01-delay-user-to-app.sh

access:
	./scripts/print-access.sh

teardown:
	./teardown.sh
