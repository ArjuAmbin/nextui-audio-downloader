#!/bin/sh
# Audio Downloader - a NextUI Tool pak
# Search & download music (YouTube Music) and podcast episodes (iTunes + RSS).
# Download-only. No playback functionality is included on purpose.
#
# Requires these binaries to be present and executable (see README.md):
#   bin/tg5040/minui-list
#   bin/tg5040/minui-keyboard
#   bin/tg5040/minui-presenter
#   bin/tg5040/wget      (already included, copied from Music Player pak)
#   bin/tg5040/yt-dlp    (already included, copied from Music Player pak)

PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"

# Always-on breadcrumb written with plain redirection (not exec) directly
# next to launch.sh, so there's a way to tell the script actually started
# even if $LOGS_PATH turns out to be unset/unwritable.
printf 'launch.sh started\nPAK_DIR=%s\nPAK_NAME=%s\nPLATFORM=%s\nLOGS_PATH=%s\nUSERDATA_PATH=%s\nSDCARD_PATH=%s\n' \
    "$PAK_DIR" "$PAK_NAME" "$PLATFORM" "$LOGS_PATH" "$USERDATA_PATH" "$SDCARD_PATH" \
    >"$PAK_DIR/debug.txt" 2>&1

# Fall back to sane defaults if these weren't provided by the launcher for
# some reason, instead of dying silently on the mkdir/exec below.
: "${PLATFORM:=tg5040}"
: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${LOGS_PATH:=$SDCARD_PATH/.userdata/$PLATFORM/logs}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"

# Full command tracing (`set -x`) writes one line per shell command to the
# log file below -- with several menu layers now in place that's a lot of
# small writes to the SD card between screens, and was a real contributor
# to navigation feeling laggy. Keep it opt-in: create an empty file named
# DEBUG right next to launch.sh (i.e. inside "Audio Downloader.pak/") to
# turn it back on when something needs troubleshooting from the log file.
if [ -f "$PAK_DIR/DEBUG" ]; then
    set -x
fi
mkdir -p "$LOGS_PATH"
rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1
echo "$0" "$@"
echo "made it past log redirection" >>"$PAK_DIR/debug.txt"

cd "$PAK_DIR" || exit 1

architecture=arm
if uname -m | grep -q '64'; then
    architecture=arm64
fi

export HOME="$USERDATA_PATH/$PAK_NAME"
mkdir -p "$HOME"
export LD_LIBRARY_PATH="$PAK_DIR/lib/$PLATFORM:$PAK_DIR/lib:$LD_LIBRARY_PATH"
export PATH="$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"

WORK=/tmp/musicdl
mkdir -p "$WORK"

MUSIC_DIR="$SDCARD_PATH/Music/Downloaded"
PODCAST_DIR="$SDCARD_PATH/Podcasts"

# persisted in $HOME (not $WORK, which is /tmp and gets wiped) so search
# history and subscriptions survive across launches/reboots
MUSIC_HISTORY_FILE="$HOME/music_search_history.txt"
PODCAST_HISTORY_FILE="$HOME/podcast_search_history.txt"
PODCAST_SUBS_FILE="$HOME/podcast_subscriptions.tsv"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

sanitize() {
    # strip only the characters that are actually invalid in a FAT32/exFAT
    # filename (\ / : * ? " < > |). Colon gets a nicer substitute (" -")
    # since it shows up constantly in real titles ("Show: Episode Name");
    # the rest fall back to underscore since there's no natural equivalent.
    # (uses printf, not echo -- echo may reinterpret backslash sequences)
    printf '%s' "$1" | sed -e 's/:/ -/g' -e 's/[\\/*?"<>|]/_/g'
}

paste2() {
    # portable replacement for `paste file1 file2` (tab-joins matching
    # lines) -- BusyBox on this device doesn't ship a `paste` binary
    awk -F'\t' 'NR==FNR{a[NR]=$0;next}{print a[FNR] "\t" $0}' "$1" "$2"
}

urlencode() {
    s="$1"
    len=${#s}
    i=1
    out=""
    while [ "$i" -le "$len" ]; do
        c=$(printf '%s' "$s" | cut -c"$i")
        case "$c" in
            [a-zA-Z0-9.~_-]) out="$out$c" ;;
            " ") out="${out}%20" ;;
            *) out="$out$(printf '%%%02X' "'$c")" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

show_message() {
    message="$1"
    seconds="$2"
    [ -z "$seconds" ] && seconds="forever"
    killall minui-presenter >/dev/null 2>&1 || true
    printf '%s\n' "$message" 1>&2
    if [ "$seconds" = "forever" ]; then
        minui-presenter --message "$message" --timeout -1 &
    else
        minui-presenter --message "$message" --timeout "$seconds"
    fi
}

pick_from_list() {
    # $1 = title, $2 = confirm-text, $3 = file with one entry per line,
    # $4 = optional action button (e.g. "X"), $5 = optional action text.
    # selected text is left in $WORK/selected.txt ; returns minui-list exit
    # code (0 = confirmed, 2/3 = cancelled, 4 = action button pressed)
    title="$1"
    confirm="$2"
    srcfile="$3"
    action_button="$4"
    action_text="$5"
    rm -f "$WORK/selected.txt"
    killall minui-presenter >/dev/null 2>&1 || true
    if [ -n "$action_button" ]; then
        minui-list --disable-auto-sleep --file "$srcfile" --format text \
            --title "$title" --confirm-text "$confirm" --cancel-text "BACK" \
            --action-button "$action_button" --action-text "$action_text" \
            --write-location "$WORK/selected.txt"
    else
        minui-list --disable-auto-sleep --file "$srcfile" --format text \
            --title "$title" --confirm-text "$confirm" --cancel-text "BACK" \
            --write-location "$WORK/selected.txt"
    fi
    return $?
}

ask_text() {
    # $1 = title -> prints entered text to stdout, returns minui-keyboard exit code
    # NOTE: this function's stdout is meant to be captured via $(...) by the
    # caller, so minui-keyboard's own stdout chatter (it prints SDL/joystick
    # init lines like "[INFO] Joystick added...") must NOT go to fd1 here or
    # it gets mixed into the returned text. Redirect it to fd2 instead, which
    # still lands in the pak's log file thanks to the earlier `exec 2>&1`.
    title="$1"
    rm -f "$WORK/kb.txt"
    killall minui-presenter >/dev/null 2>&1 || true
    minui-keyboard --title "$title" --write-location "$WORK/kb.txt" 1>&2
    rc=$?
    [ -f "$WORK/kb.txt" ] && cat "$WORK/kb.txt"
    return $rc
}

add_history() {
    # $1 = history file, $2 = query -> move $2 to the top (deduped),
    # capped at 10 entries. Tmp file is a sibling of $1 so the final mv
    # stays on the same filesystem as $HOME (unlike $WORK, which is /tmp).
    file="$1"
    query="$2"
    [ -z "$query" ] && return
    { printf '%s\n' "$query"; [ -f "$file" ] && grep -vFx "$query" "$file"; } \
        | head -n 10 >"$file.tmp"
    mv "$file.tmp" "$file"
}

# ---------------------------------------------------------------------------
# music: search + download via YouTube Music (same source the original
# Music Player pak used)
# ---------------------------------------------------------------------------

music_search_flow() {
    # $1 = search query
    query="$1"
    [ -z "$query" ] && return

    show_message "Searching for \"$query\"..." forever
    enc="$(urlencode "$query")"
    # use an unusual custom delimiter instead of \t -- some cut/sed builds
    # on this device weren't splitting on it reliably, which is almost
    # certainly why titles showed up as "id/garbage/Title" glued together
    yt-dlp "https://music.youtube.com/search?q=${enc}#songs" \
        --flat-playlist -I :20 --no-warnings --socket-timeout 15 \
        --print '%(id)s@@@%(title)s' \
        >"$WORK/yt_results.raw" 2>"$WORK/yt_error.txt"
    killall minui-presenter >/dev/null 2>&1 || true

    if [ ! -s "$WORK/yt_results.raw" ]; then
        echo "--- yt-dlp search produced no results. stderr was: ---"
        cat "$WORK/yt_error.txt"
        echo "--- end yt-dlp stderr ---"
        show_message "No results found" 2
        return
    fi

    awk -F'@@@' '{print $2}' "$WORK/yt_results.raw" >"$WORK/yt_titles.txt"

    pick_from_list "Select a Song" "DOWNLOAD" "$WORK/yt_titles.txt"
    rc=$?
    [ $rc -ne 0 ] && return

    selected_title="$(cat "$WORK/selected.txt")"
    line_no="$(grep -nFx "$selected_title" "$WORK/yt_titles.txt" | head -1 | cut -d: -f1)"
    [ -z "$line_no" ] && { show_message "Could not match selection" 2; return; }
    video_id="$(awk -F'@@@' -v n="$line_no" 'NR==n{print $1}' "$WORK/yt_results.raw")"

    mkdir -p "$MUSIC_DIR"
    safe_title="$(sanitize "$selected_title")"
    tmp_file="$MUSIC_DIR/.downloading_${video_id}.m4a"
    final_file="$MUSIC_DIR/${safe_title}.m4a"

    if [ -f "$final_file" ]; then
        show_message "Already downloaded" 2
        return
    fi

    show_message "Downloading:
$selected_title" forever
    yt-dlp -f "bestaudio[ext=m4a]/bestaudio/best" --embed-metadata --socket-timeout 30 \
        --parse-metadata "title:%(artist)s - %(title)s" --newline --progress \
        -o "$tmp_file" --no-playlist \
        "https://music.youtube.com/watch?v=${video_id}"
    rc=$?
    killall minui-presenter >/dev/null 2>&1 || true

    if [ $rc -eq 0 ] && [ -f "$tmp_file" ]; then
        mv "$tmp_file" "$final_file"
        show_message "Saved to Music/Downloaded" 2
    else
        rm -f "$tmp_file"
        show_message "Download failed - see logs" 2
    fi
}

music_search_entry() {
    # bound directly to the main menu's "Search Music" entry -- goes
    # straight to the keyboard, no intermediate menu screen
    query="$(ask_text "Search Music")"
    rc=$?
    [ $rc -ne 0 ] && return
    [ -z "$query" ] && return
    add_history "$MUSIC_HISTORY_FILE" "$query"
    music_search_flow "$query"
}

music_history_flow() {
    while true; do
        if [ ! -s "$MUSIC_HISTORY_FILE" ]; then
            show_message "No search history yet" 2
            return
        fi

        pick_from_list "Music History" "SEARCH AGAIN" "$MUSIC_HISTORY_FILE" "X" "CLEAR ALL"
        rc=$?
        if [ $rc -eq 4 ]; then
            rm -f "$MUSIC_HISTORY_FILE"
            show_message "History cleared" 1
            continue
        elif [ $rc -ne 0 ]; then
            return
        fi

        query="$(cat "$WORK/selected.txt")"
        [ -z "$query" ] && continue
        add_history "$MUSIC_HISTORY_FILE" "$query"
        music_search_flow "$query"
    done
}

# ---------------------------------------------------------------------------
# podcasts: search iTunes for a show, list its RSS feed, download an episode
# ---------------------------------------------------------------------------

itunes_search() {
    # $1 = query -> writes $WORK/shows.tsv (name<TAB>feedUrl)
    enc="$(urlencode "$1")"
    wget --no-check-certificate -qO- -T 20 -t 2 -U "NextUI-Music-Downloader" \
        "https://itunes.apple.com/search?term=${enc}&media=podcast&limit=15" \
        >"$WORK/itunes.json" 2>"$WORK/itunes_error.txt"

    # crude but dependency-free JSON scraping: pull matching
    # collectionName / feedUrl pairs in document order.
    grep -oE '"collectionName":"([^"\\]|\\.)*"' "$WORK/itunes.json" \
        | sed -e 's/^"collectionName":"//' -e 's/"$//' \
        | sed 's/\\"/"/g' >"$WORK/show_names.txt"
    grep -oE '"feedUrl":"([^"\\]|\\.)*"' "$WORK/itunes.json" \
        | sed -e 's/^"feedUrl":"//' -e 's/"$//' \
        | sed 's/\\\//\//g' >"$WORK/show_feeds.txt"
    paste2 "$WORK/show_names.txt" "$WORK/show_feeds.txt" >"$WORK/shows.tsv"
}

parse_feed() {
    # $1 = feed url -> writes $WORK/episodes.tsv (title<TAB>enclosure_url)
    wget --no-check-certificate -qO- -T 30 -t 2 -U "NextUI-Music-Downloader" "$1" \
        >"$WORK/feed.xml" 2>"$WORK/feed_error.txt"

    # only look inside <item>...</item> blocks so the channel-level
    # title (the show name) is not picked up as an "episode"
    sed -n '/<item[ >]/,$p' "$WORK/feed.xml" >"$WORK/feed_items.xml"

    grep -oE '<title>(<!\[CDATA\[)?[^<]*(\]\]>)?</title>' "$WORK/feed_items.xml" \
        | sed -e 's/<title>//' -e 's/<\/title>//' \
              -e 's/<!\[CDATA\[//' -e 's/\]\]>//' >"$WORK/ep_titles.txt"

    grep -oE '<enclosure[^>]*url="[^"]*"' "$WORK/feed_items.xml" \
        | grep -oE 'url="[^"]*"' | sed -e 's/url="//' -e 's/"$//' >"$WORK/ep_urls.txt"

    paste2 "$WORK/ep_titles.txt" "$WORK/ep_urls.txt" | head -30 >"$WORK/episodes.tsv"
}

podcast_episode_flow() {
    # $1 = show name, $2 = feed url -> list current episodes (always
    # fetched fresh, never cached) and download the one picked
    show_name="$1"
    feed_url="$2"

    show_message "Loading episodes..." forever
    parse_feed "$feed_url"
    killall minui-presenter >/dev/null 2>&1 || true

    if [ ! -s "$WORK/episodes.tsv" ]; then
        echo "--- feed produced no episodes. feed url: $feed_url ---"
        echo "--- wget stderr: ---"
        cat "$WORK/feed_error.txt" 2>/dev/null
        echo "--- feed.xml (first 20 lines): ---"
        head -20 "$WORK/feed.xml" 2>/dev/null
        echo "--- end diagnostics ---"
        show_message "No episodes found in feed" 2
        return
    fi

    cut -f1 "$WORK/episodes.tsv" >"$WORK/ep_titles_list.txt"
    pick_from_list "$show_name" "DOWNLOAD" "$WORK/ep_titles_list.txt"
    rc=$?
    [ $rc -ne 0 ] && return

    selected_ep="$(cat "$WORK/selected.txt")"
    line_no="$(grep -nFx "$selected_ep" "$WORK/ep_titles_list.txt" | head -1 | cut -d: -f1)"
    [ -z "$line_no" ] && { show_message "Could not match selection" 2; return; }
    ep_url="$(sed -n "${line_no}p" "$WORK/episodes.tsv" | cut -f2)"

    case "$ep_url" in
        *.mp3*) ext=mp3 ;;
        *.m4a*) ext=m4a ;;
        *.aac*) ext=aac ;;
        *.ogg*) ext=ogg ;;
        *.wav*) ext=wav ;;
        *) ext=mp3 ;;
    esac

    show_dir="$PODCAST_DIR/$(sanitize "$show_name")"
    mkdir -p "$show_dir"
    ep_safe="$(sanitize "$selected_ep")"
    tmp_file="$show_dir/.downloading_${ep_safe}.$ext"
    final_file="$show_dir/${ep_safe}.$ext"

    if [ -f "$final_file" ]; then
        show_message "Already downloaded" 2
        return
    fi

    show_message "Downloading:
$selected_ep" forever
    wget --no-check-certificate -T 60 -t 2 -U "NextUI-Music-Downloader" \
        -O "$tmp_file" "$ep_url"
    rc=$?
    killall minui-presenter >/dev/null 2>&1 || true

    if [ $rc -eq 0 ] && [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$final_file"
        show_message "Saved to Podcasts" 2
    else
        rm -f "$tmp_file"
        show_message "Download failed - see logs" 2
    fi
}

podcast_is_subscribed() {
    # $1 = feed url -> exit 0 if subscribed, 1 otherwise
    feed_url="$1"
    [ -f "$PODCAST_SUBS_FILE" ] || return 1
    awk -F'\t' -v u="$feed_url" '$2==u{found=1} END{exit !found}' "$PODCAST_SUBS_FILE"
}

podcast_subscribe() {
    # $1 = show name, $2 = feed url
    show_name="$1"
    feed_url="$2"
    podcast_is_subscribed "$feed_url" && return
    printf '%s\t%s\n' "$show_name" "$feed_url" >>"$PODCAST_SUBS_FILE"
}

podcast_unsubscribe() {
    # $1 = feed url
    feed_url="$1"
    [ -f "$PODCAST_SUBS_FILE" ] || return
    awk -F'\t' -v u="$feed_url" '$2!=u' "$PODCAST_SUBS_FILE" >"$PODCAST_SUBS_FILE.tmp"
    mv "$PODCAST_SUBS_FILE.tmp" "$PODCAST_SUBS_FILE"
}

podcast_search_flow() {
    # $1 = search query -> confirm opens episodes directly, X toggles
    # Subscribe/Unsubscribe on the highlighted show without leaving this
    # list (no separate action-menu screen)
    query="$1"
    [ -z "$query" ] && return

    show_message "Searching for \"$query\"..." forever
    itunes_search "$query"
    killall minui-presenter >/dev/null 2>&1 || true

    if [ ! -s "$WORK/shows.tsv" ]; then
        echo "--- iTunes search produced no shows. wget stderr: ---"
        cat "$WORK/itunes_error.txt" 2>/dev/null
        echo "--- raw itunes.json (first 40 lines): ---"
        head -40 "$WORK/itunes.json" 2>/dev/null
        echo "--- end diagnostics ---"
        show_message "No shows found" 2
        return
    fi

    cut -f1 "$WORK/shows.tsv" >"$WORK/show_names_list.txt"

    while true; do
        pick_from_list "Select a Show" "VIEW EPISODES" "$WORK/show_names_list.txt" "X" "TOGGLE SUB"
        rc=$?
        [ $rc -ne 0 ] && [ $rc -ne 4 ] && return

        selected_show="$(cat "$WORK/selected.txt")"
        [ -z "$selected_show" ] && continue
        line_no="$(grep -nFx "$selected_show" "$WORK/show_names_list.txt" | head -1 | cut -d: -f1)"
        [ -z "$line_no" ] && { show_message "Could not match selection" 2; continue; }
        feed_url="$(sed -n "${line_no}p" "$WORK/shows.tsv" | cut -f2)"

        if [ -z "$feed_url" ]; then
            show_message "No RSS feed for that show" 2
            continue
        fi

        if [ "$rc" -eq 4 ]; then
            if podcast_is_subscribed "$feed_url"; then
                podcast_unsubscribe "$feed_url"
                show_message "Unsubscribed" 1
            else
                podcast_subscribe "$selected_show" "$feed_url"
                show_message "Subscribed" 1
            fi
            continue
        fi

        podcast_episode_flow "$selected_show" "$feed_url"
    done
}

podcast_subscriptions_flow() {
    # confirm opens episodes directly (always re-fetching the feed live);
    # X unsubscribes the highlighted show without leaving this list
    while true; do
        if [ ! -s "$PODCAST_SUBS_FILE" ]; then
            show_message "No subscriptions yet" 2
            return
        fi

        cut -f1 "$PODCAST_SUBS_FILE" | sort >"$WORK/sub_names_list.txt"
        pick_from_list "Subscriptions" "VIEW EPISODES" "$WORK/sub_names_list.txt" "X" "UNSUBSCRIBE"
        rc=$?
        [ $rc -ne 0 ] && [ $rc -ne 4 ] && return

        selected_show="$(cat "$WORK/selected.txt")"
        [ -z "$selected_show" ] && continue
        feed_url="$(awk -F'\t' -v n="$selected_show" '$1==n{print $2; exit}' "$PODCAST_SUBS_FILE")"
        [ -z "$feed_url" ] && continue

        if [ "$rc" -eq 4 ]; then
            podcast_unsubscribe "$feed_url"
            show_message "Unsubscribed" 1
            continue
        fi

        podcast_episode_flow "$selected_show" "$feed_url"
    done
}

podcast_search_entry() {
    # bound directly to the main menu's "Search Podcast" entry -- goes
    # straight to the keyboard, no intermediate menu screen
    query="$(ask_text "Search Podcast")"
    rc=$?
    [ $rc -ne 0 ] && return
    [ -z "$query" ] && return
    add_history "$PODCAST_HISTORY_FILE" "$query"
    podcast_search_flow "$query"
}

podcast_history_flow() {
    while true; do
        if [ ! -s "$PODCAST_HISTORY_FILE" ]; then
            show_message "No search history yet" 2
            return
        fi

        pick_from_list "Podcast History" "SEARCH AGAIN" "$PODCAST_HISTORY_FILE" "X" "CLEAR ALL"
        rc=$?
        if [ $rc -eq 4 ]; then
            rm -f "$PODCAST_HISTORY_FILE"
            show_message "History cleared" 1
            continue
        elif [ $rc -ne 0 ]; then
            return
        fi

        query="$(cat "$WORK/selected.txt")"
        [ -z "$query" ] && continue
        add_history "$PODCAST_HISTORY_FILE" "$query"
        podcast_search_flow "$query"
    done
}

# ---------------------------------------------------------------------------
# files: browse Music/Downloaded and Podcasts/<Show>, rename or delete
# ---------------------------------------------------------------------------

rename_file() {
    # $1 = dir, $2 = current filename
    dir="$1"
    old_name="$2"

    case "$old_name" in
        *.*) ext="${old_name##*.}" ;;
        *) ext="" ;;
    esac

    new_base="$(ask_text "New name for:
$old_name")"
    rc=$?
    [ $rc -ne 0 ] && return
    [ -z "$new_base" ] && return

    safe_base="$(sanitize "$new_base")"
    if [ -z "$safe_base" ]; then
        show_message "Invalid name" 2
        return
    fi
    new_name="$safe_base${ext:+.$ext}"

    [ "$new_name" = "$old_name" ] && return

    if [ -e "$dir/$new_name" ]; then
        show_message "A file named
$new_name
already exists" 2
        return
    fi

    if mv "$dir/$old_name" "$dir/$new_name"; then
        show_message "Renamed" 1
    else
        show_message "Rename failed - see logs" 2
    fi
}

delete_file() {
    # $1 = dir, $2 = filename
    dir="$1"
    name="$2"

    if rm -f "$dir/$name"; then
        show_message "Deleted" 1
    else
        show_message "Delete failed - see logs" 2
        return
    fi

    # if that was the last episode in a podcast show folder, remove the
    # now-empty folder too so it stops cluttering the shows list
    case "$dir" in
        "$PODCAST_DIR"/*)
            [ -z "$(ls -A "$dir" 2>/dev/null)" ] && rmdir "$dir" 2>/dev/null
            ;;
    esac
}

file_actions() {
    # $1 = dir, $2 = filename
    dir="$1"
    name="$2"

    printf 'Rename\nDelete\n' >"$WORK/file_action_menu.txt"
    pick_from_list "$name" "SELECT" "$WORK/file_action_menu.txt"
    rc=$?
    [ $rc -ne 0 ] && return

    action="$(cat "$WORK/selected.txt")"
    case "$action" in
        Rename) rename_file "$dir" "$name" ;;
        Delete) delete_file "$dir" "$name" ;;
    esac
}

browse_files_dir() {
    # $1 = dir, $2 = title -> list plain files in $dir, act on the pick
    dir="$1"
    title="$2"

    while true; do
        for entry in "$dir"/*; do
            [ -f "$entry" ] || continue
            printf '%s\n' "${entry##*/}"
        done | sort >"$WORK/files_list.txt"

        if [ ! -s "$WORK/files_list.txt" ]; then
            show_message "No files here" 2
            return
        fi

        pick_from_list "$title" "SELECT" "$WORK/files_list.txt"
        rc=$?
        [ $rc -ne 0 ] && return

        selected_file="$(cat "$WORK/selected.txt")"
        [ -z "$selected_file" ] && continue
        [ -f "$dir/$selected_file" ] || continue

        file_actions "$dir" "$selected_file"
    done
}

browse_podcast_shows() {
    while true; do
        for entry in "$PODCAST_DIR"/*; do
            [ -d "$entry" ] || continue
            printf '%s\n' "${entry##*/}"
        done | sort >"$WORK/show_dirs.txt"

        if [ ! -s "$WORK/show_dirs.txt" ]; then
            show_message "No podcasts downloaded yet" 2
            return
        fi

        pick_from_list "Podcasts" "OPEN" "$WORK/show_dirs.txt"
        rc=$?
        [ $rc -ne 0 ] && return

        selected_show="$(cat "$WORK/selected.txt")"
        [ -z "$selected_show" ] && continue

        browse_files_dir "$PODCAST_DIR/$selected_show" "$selected_show"
    done
}

files_flow() {
    printf 'Music\nPodcasts\n' >"$WORK/files_menu.txt"
    while true; do
        pick_from_list "Files" "OPEN" "$WORK/files_menu.txt"
        rc=$?
        [ $rc -ne 0 ] && return

        choice="$(cat "$WORK/selected.txt")"
        case "$choice" in
            "Music") browse_files_dir "$MUSIC_DIR" "Music" ;;
            "Podcasts") browse_podcast_shows ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# settings: update the bundled yt-dlp binary in place
# ---------------------------------------------------------------------------

update_ytdlp() {
    ytdlp_path="$(command -v yt-dlp)"
    if [ -z "$ytdlp_path" ]; then
        show_message "yt-dlp not found" 2
        return
    fi

    show_message "Checking for yt-dlp updates..." forever
    yt-dlp -U >"$WORK/ytdlp_update.log" 2>&1
    rc=$?
    killall minui-presenter >/dev/null 2>&1 || true

    echo "--- yt-dlp -U output (exit code $rc): ---"
    cat "$WORK/ytdlp_update.log"
    echo "--- end yt-dlp -U output ---"

    # yt-dlp uses exit code 100 to mean "an update happened, restart to use
    # it" -- it is NOT necessarily a failure, so don't treat every non-zero
    # code as an error. Just surface its own summary line either way.
    result_line="$(grep -E '^(yt-dlp is up to date|Updated|ERROR|Current version)' "$WORK/ytdlp_update.log" | tail -1)"
    [ -z "$result_line" ] && result_line="$(tail -1 "$WORK/ytdlp_update.log")"
    show_message "$result_line" 4
}

# ---------------------------------------------------------------------------
# main menu
# ---------------------------------------------------------------------------

cleanup() {
    killall minui-presenter >/dev/null 2>&1 || true
}
trap "cleanup" EXIT INT TERM HUP QUIT

if ! command -v minui-list >/dev/null 2>&1; then
    echo "FATAL: minui-list not found on PATH ($PATH)" >>"$PAK_DIR/debug.txt"
    show_message "minui-list not found - see README" 3
    exit 1
fi
if ! command -v minui-keyboard >/dev/null 2>&1; then
    echo "FATAL: minui-keyboard not found on PATH ($PATH)" >>"$PAK_DIR/debug.txt"
    show_message "minui-keyboard not found - see README" 3
    exit 1
fi
if ! command -v minui-presenter >/dev/null 2>&1; then
    echo "FATAL: minui-presenter not found on PATH ($PATH)" >>"$PAK_DIR/debug.txt"
    show_message "minui-presenter not found - see README" 3
    exit 1
fi
echo "all three minui-* tools found, entering main menu" >>"$PAK_DIR/debug.txt"

printf 'Search Music\nMusic History\nSearch Podcast\nPodcast History\nPodcast Subscriptions\nFiles\nUpdate yt-dlp\n' >"$WORK/main_menu.txt"

while true; do
    pick_from_list "Audio Downloader" "SELECT" "$WORK/main_menu.txt"
    rc=$?
    [ $rc -ne 0 ] && break

    choice="$(cat "$WORK/selected.txt")"
    case "$choice" in
        "Search Music") music_search_entry ;;
        "Music History") music_history_flow ;;
        "Search Podcast") podcast_search_entry ;;
        "Podcast History") podcast_history_flow ;;
        "Podcast Subscriptions") podcast_subscriptions_flow ;;
        "Files") files_flow ;;
        "Update yt-dlp") update_ytdlp ;;
    esac
done

exit 0
