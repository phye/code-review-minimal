# Makefile for code-review-minimal

EMACS ?= emacs

.PHONY: test clean

test:
	$(EMACS) -batch --eval "(add-to-list 'load-path \".\")" \
		-l ert -l test/code-review-minimal-test.el \
		-f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc
