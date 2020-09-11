PANDOC := $(shell command -v pandoc 2> /dev/null)

all:
ifndef PANDOC
    $(error "pandoc is not available, please install it - https://pandoc.org/installing.html")
endif
	@pandoc -s --toc -H modest.css -f markdown -t html5 cilium.md -o cilium.html
