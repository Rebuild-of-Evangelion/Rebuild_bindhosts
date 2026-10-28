#!/bin/sh
# draft.sh - snapshot / restore the rule files edited from the WebUI
#
# The WebUI writes rule files directly, so there is no in-memory undo.
# This script keeps a copy of the rule files taken before the first edit,
# so "unapplied changes" can be detected and discarded.
#
# Hosts and proxy keep separate snapshots, fully independent: editing half of
# one view and switching to the other leaves both intact.
#
# usage: draft.sh <action> [hosts|proxy]
#
#   save     take a snapshot if none exists (no-op when one is already there)
#   mark     save (if needed) and flag that something was edited
#   discard  restore the snapshot and drop it
#   clear    drop the snapshot (used after bindhosts.sh --action succeeds)
#   status   prints "dirty" when there are unapplied edits, else "clean"
#
# When the view argument is omitted:
#   save/mark/discard default to hosts
#   clear drops both
#   status reports dirty if either view is dirty

PERSISTENT_DIR="${BH_PERSISTENT_DIR:-/data/adb/bindhosts}"
DRAFT_ROOT="$PERSISTENT_DIR/.draft"

# Files owned by a view, relative to PERSISTENT_DIR.
rule_files() {
	_view="$1"
	(
		cd "$PERSISTENT_DIR" 2>/dev/null || exit 0
		for f in "$_view"/*.txt "$_view"/imported/*.txt "$_view"/imported/*.txt.disabled ; do
			[ -f "$f" ] && echo "$f"
		done
	)
}

take_snapshot() {
	_view="$1"
	_d="$DRAFT_ROOT/$_view"
	[ -d "$_d" ] && return 0
	mkdir -p "$_d/files" || return 1
	rule_files "$_view" | while read -r f ; do
		[ -n "$f" ] || continue
		# Strip the view prefix; snapshots use paths relative to the view root.
		rel="${f#$_view/}"
		mkdir -p "$_d/files/$(dirname "$rel")"
		cp -f "$PERSISTENT_DIR/$f" "$_d/files/$rel"
	done
	return 0
}

discard_view() {
	_view="$1"
	_d="$DRAFT_ROOT/$_view"
	[ -d "$_d" ] || return 0

	# Drop the view's current files first, then restore the snapshot.
	rule_files "$_view" | while read -r f ; do
		[ -n "$f" ] && rm -f "$PERSISTENT_DIR/$f"
	done

	if [ -d "$_d/files" ] ; then
		(
			cd "$_d/files" || exit 0
			find . -type f | sed 's|^\./||'
		) | while read -r rel ; do
			[ -n "$rel" ] || continue
			mkdir -p "$PERSISTENT_DIR/$_view/$(dirname "$rel")"
			cp -f "$_d/files/$rel" "$PERSISTENT_DIR/$_view/$rel"
		done
	fi

	rm -rf "$_d"
}

view="${2:-hosts}"

case "$1" in
save)
	take_snapshot "$view"
	;;
mark)
	take_snapshot "$view" || exit 1
	: > "$DRAFT_ROOT/$view/dirty"
	;;
discard)
	discard_view "$view"
	;;
clear)
	if [ -n "$2" ] ; then
		rm -rf "$DRAFT_ROOT/$2"
	else
		# After a successful apply both views are considered written.
		rm -rf "$DRAFT_ROOT"
	fi
	;;
status)
	if [ -n "$2" ] ; then
		[ -f "$DRAFT_ROOT/$2/dirty" ] && echo dirty || echo clean
	elif [ -f "$DRAFT_ROOT/hosts/dirty" ] || [ -f "$DRAFT_ROOT/proxy/dirty" ] ; then
		echo dirty
	else
		echo clean
	fi
	;;
*)
	echo "usage: draft.sh save|mark|discard|clear|status [hosts|proxy]" >&2
	exit 1
	;;
esac
