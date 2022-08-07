all: verify-dependencies check lint

# Do not run targets line-by-line, but as a single invocation.
.ONESHELL:
# Suppress verbose output.
.SILENT:

link:
	rm -f $(HOME)/.local/bin/alfred > /dev/null
	ln -s $(shell pwd)/alfred.bash $(HOME)/.local/bin/alfred

verify-shellcheck:
	# Check if shellcheck is not installed.
	if [ ! -x $(which shellcheck) ]; then
		echo "shellcheck is not installed."
		exit 1
	fi

verify-shfmt:
	# Check if shfmt is not installed.
	if [ ! -x $(which shfmt) ]; then
		echo "shfmt is not installed."
		exit 1
	fi

verify-dependencies: verify-shellcheck verify-shfmt

check: verify-shellcheck
	shellcheck $(shell pwd)/alfred.bash

diff: verify-shfmt
	shfmt -d $(shell pwd)/alfred.bash | `git config core.pager`

lint: verify-shfmt
	shfmt -w $(shell pwd)/alfred.bash

simplify: verify-shfmt
	shfmt -s -w $(shell pwd)/alfred.bash