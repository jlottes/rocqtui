#!/bin/sh
echo "TERM=$TERM"
echo "TERMINFO_DIRS=$TERMINFO_DIRS"
infocmp glterm 2>&1 | head -1
