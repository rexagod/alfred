link:
	rm -f $(HOME)/.local/bin/alfred > /dev/null
	ln -s $(shell pwd)/alfred.bash $(HOME)/.local/bin/alfred

check:
	shellcheck $(shell pwd)/alfred.bash