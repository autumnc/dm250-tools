#!/bin/sh
if tmux display-popup -C 2>/dev/null; then
	:
else
	tmux display-popup -w 100% -h 50% -E 'aichat --simple'
fi
