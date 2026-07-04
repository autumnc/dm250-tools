PATH=/opt/bin:/root/bin:/usr/local/bin:$PATH
loadkeys /opt/share/keymap/dm200_console.map
export XDG_CONFIG_HOME=/root/.config
export TERM_PROGRAM="foot"
export EDITOR="nvim"
export LD_PRELOAD=/usr/lib/getrandom-fix.so
alias ls='eza --icons=auto'
alias lt='eza --icons=auto -T --level=3'
alias yazi='TERM=foot yazi'
/opt/bin/backlight 100

CURRENT_IM=fcitx5

if [ -z "$FBTERM" ] && [ -z "$TMUX" ] && [ "$TERM" = "linux" ] && [ -z "$FBTERM_FALLBACK" ]; then
	if [ "$CURRENT_IM" = "fcitx5" ]; then
    export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address)
		fcitx5 -d 2>/dev/null
		fbterm-mod -i fcitx5-fbterm -- tmux new-session -A "pjournal"
	else
		fbterm-mod -- tmux new-session -A "pjournal"
	fi
	export FBTERM_FALLBACK=1
	exec /bin/sh -l
fi

if [ -n "$FBTERM" ] && [ -z "$TMUX" ]; then
	exec tmux new-session -A -s "pjournal"
fi
