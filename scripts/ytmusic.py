#!/usr/bin/env python3
"""
YouTube Music backend for Omarchy sushantkr.yt-music plugin.
Features:
- Instant search via YouTube Music Innertube WEB_REMIX API
- Fallback search via yt-dlp
- Ad-free audio streaming via mpv
- Strict single-instance mpv daemon management (prevents multiple songs playing)
- Automatic continuous playback queue (YouTube Music Radio / Automix via Innertube next API)
- Manual queue management (add, clear, play index, remove index, seek)
- Seamless MPRIS integration
- Automatic metadata resolution via oEmbed
"""

import os
import sys
import json
import socket
import subprocess
import time
import re
import html
import urllib.request
import urllib.error

UID = os.getuid()
SOCKET_PATH = f"/tmp/music-flow-ytmusic-{UID}.sock"
CACHE_PATH = f"/tmp/music-flow-ytmusic-{UID}-queue.json"
MPV_MPRIS_PATH = "/usr/lib/mpv-mpris/mpris.so"

def sanitize_text(text, max_len=140):
    if not text:
        return ""
    text = re.sub(r'[\x00-\x1f\x7f]', '', str(text))
    text = html.unescape(text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text[:max_len]

def extract_video_id(query):
    if not query:
        return None
    patterns = [
        r'(?:v=|youtu\.be/|shorts/|embed/|watch\?v=)([a-zA-Z0-9_-]{11})',
        r'^([a-zA-Z0-9_-]{11})$'
    ]
    for pattern in patterns:
        match = re.search(pattern, query)
        if match:
            return match.group(1)
    return None

def parse_runs(runs):
    return ''.join(r.get('text', '') for r in runs) if runs else ''

# ----------------------------------------------------------------------
# Queue Cache Storage
# ----------------------------------------------------------------------
def load_queue_cache():
    if not os.path.exists(CACHE_PATH):
        return []
    try:
        with open(CACHE_PATH, 'r', encoding='utf-8') as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except Exception:
        return []

def save_queue_cache(items):
    try:
        tmp_path = CACHE_PATH + ".tmp"
        with open(tmp_path, 'w', encoding='utf-8') as f:
            json.dump(items, f, ensure_ascii=False)
        os.replace(tmp_path, CACHE_PATH)
    except Exception:
        pass

def resolve_oembed_metadata(vid):
    """Fetches real video title and author using lightweight YouTube oEmbed API."""
    try:
        o_url = f"https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v={vid}&format=json"
        req = urllib.request.Request(o_url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=2.5) as r:
            o_data = json.loads(r.read().decode('utf-8'))
            title = sanitize_text(o_data.get('title') or '')
            author = sanitize_text(o_data.get('author_name') or '')
            return title, author
    except Exception:
        return "", ""

# ----------------------------------------------------------------------
# YouTube Music Search
# ----------------------------------------------------------------------
def search_innertube(query, limit=8):
    data = json.dumps({
        'context': {
            'client': {
                'clientName': 'WEB_REMIX',
                'clientVersion': '1.20230515.01.00'
            }
        },
        'query': query
    }).encode('utf-8')

    req = urllib.request.Request(
        'https://music.youtube.com/youtubei/v1/search',
        data=data,
        headers={
            'Content-Type': 'application/json',
            'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
        }
    )

    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            res_data = json.loads(res.read().decode('utf-8'))
    except Exception:
        return []

    tabs = res_data.get('contents', {}).get('tabbedSearchResultsRenderer', {}).get('tabs', [])
    if not tabs:
        return []
    sections = tabs[0].get('tabRenderer', {}).get('content', {}).get('sectionListRenderer', {}).get('contents', [])

    results = []
    seen_ids = set()

    def add_result(vid, title, artist, duration):
        if not vid or vid in seen_ids or len(vid) != 11:
            return
        title = sanitize_text(title)
        if not title:
            return

        artist = sanitize_text(artist)
        if artist.startswith('Song • '):
            artist = artist[7:]
        elif artist.startswith('Video • '):
            artist = artist[8:]
        if ' • ' in artist:
            parts = artist.split(' • ')
            artist = parts[0]
            if len(parts) > 1 and (':' in parts[-1] or 'views' in parts[-1] or 'plays' in parts[-1]):
                if not duration:
                    duration = parts[-1]

        seen_ids.add(vid)
        results.append({
            'id': vid,
            'title': title,
            'artist': artist or 'YouTube Music',
            'duration': duration or '',
            'thumbnail': f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"
        })

    def process_item(item):
        if not item:
            return
        m = item.get('musicResponsiveListItemRenderer')
        if not m:
            return
        flex = m.get('flexColumns', [])
        title = ''
        artist = ''
        duration = ''
        for i, col in enumerate(flex):
            txt = parse_runs(col.get('musicResponsiveListItemFlexColumnRenderer', {}).get('text', {}).get('runs', []))
            if i == 0:
                title = txt
            elif i == 1:
                artist = txt
            elif i == 2:
                duration = txt
        vid = ''
        overlay = m.get('overlay', {}).get('musicItemThumbnailOverlayRenderer', {})
        vid = overlay.get('content', {}).get('musicPlayButtonRenderer', {}).get('playNavigationEndpoint', {}).get('watchEndpoint', {}).get('videoId', '')
        if not vid:
            for col in flex:
                runs = col.get('musicResponsiveListItemFlexColumnRenderer', {}).get('text', {}).get('runs', [])
                for r in runs:
                    v = r.get('navigationEndpoint', {}).get('watchEndpoint', {}).get('videoId', '')
                    if v:
                        vid = v
                        break
                if vid:
                    break
        if vid and title:
            add_result(vid, title, artist, duration)

    for sec in sections:
        if len(results) >= limit:
            break
        if 'musicCardShelfRenderer' in sec:
            card = sec['musicCardShelfRenderer']
            t = parse_runs(card.get('title', {}).get('runs', []))
            sub = parse_runs(card.get('subtitle', {}).get('runs', []))
            vid = ''
            for r in card.get('title', {}).get('runs', []):
                v = r.get('navigationEndpoint', {}).get('watchEndpoint', {}).get('videoId', '')
                if v:
                    vid = v
                    break
            if vid and t:
                add_result(vid, t, sub, "")
        elif 'musicShelfRenderer' in sec:
            for it in sec['musicShelfRenderer'].get('contents', []):
                if len(results) >= limit:
                    break
                process_item(it)
        elif 'itemSectionRenderer' in sec:
            for it in sec['itemSectionRenderer'].get('contents', []):
                if len(results) >= limit:
                    break
                process_item(it)

    return results

def search_ytdlp_fallback(query, limit=5):
    try:
        proc = subprocess.run(
            ['yt-dlp', '--extractor-args', 'youtube:player_client=android', f'ytsearch{limit}:{query}', '--dump-json', '--flat-playlist'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=6
        )
        results = []
        for line in proc.stdout.splitlines():
            try:
                item = json.loads(line)
            except Exception:
                continue
            vid = item.get('id', '')
            title = sanitize_text(item.get('title', ''))
            uploader = sanitize_text(item.get('uploader') or item.get('channel') or '')
            duration = sanitize_text(item.get('duration_string', ''))
            if vid and title and len(vid) == 11:
                results.append({
                    'id': vid,
                    'title': title,
                    'artist': uploader or 'YouTube Music',
                    'duration': duration,
                    'thumbnail': f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"
                })
        return results
    except Exception:
        return []

def search(query, limit=8):
    query = sanitize_text(query, 200)
    if not query:
        return []

    direct_id = extract_video_id(query)
    if direct_id:
        t, a = resolve_oembed_metadata(direct_id)
        return [{
            'id': direct_id,
            'title': t or f'YouTube Video ({direct_id})',
            'artist': a or 'YouTube Music',
            'duration': '',
            'thumbnail': f"https://i.ytimg.com/vi/{direct_id}/hqdefault.jpg"
        }]

    # 1. Search YouTube Music Innertube API
    results = search_innertube(query, limit=limit)

    # 2. Fallback to yt-dlp if few results
    if len(results) < 2:
        fallback = search_ytdlp_fallback(query, limit=limit - len(results))
        seen = {r['id'] for r in results}
        for f in fallback:
            if f['id'] not in seen:
                results.append(f)
                seen.add(f['id'])

    return results[:limit]

# ----------------------------------------------------------------------
# YouTube Music Radio Automix Queue Generator
# ----------------------------------------------------------------------
def get_radio_tracks(video_id, limit=20):
    """Fetches YouTube Music's automix radio queue for a song using Innertube next API."""
    data = json.dumps({
        'context': {
            'client': {
                'clientName': 'WEB_REMIX',
                'clientVersion': '1.20230515.01.00'
            }
        },
        'videoId': video_id,
        'playlistId': 'RDAMVM' + video_id
    }).encode('utf-8')

    req = urllib.request.Request(
        'https://music.youtube.com/youtubei/v1/next',
        data=data,
        headers={
            'Content-Type': 'application/json',
            'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
        }
    )

    try:
        with urllib.request.urlopen(req, timeout=6) as res:
            res_data = json.loads(res.read().decode('utf-8'))
    except Exception:
        return []

    tabs = res_data.get('contents', {}).get('singleColumnMusicWatchNextResultsRenderer', {}).get('tabbedRenderer', {}).get('watchNextTabbedResultsRenderer', {}).get('tabs', [])
    if not tabs:
        return []

    items = []
    for tab in tabs:
        t = tab.get('tabRenderer', {})
        if t.get('title') == 'Up next' or not items:
            content = t.get('content', {})
            q_items = content.get('musicQueueRenderer', {}).get('content', {}).get('playlistPanelRenderer', {}).get('contents', [])
            if q_items:
                items = q_items
                break

    results = []
    seen = {video_id}

    for it in items:
        p = it.get('playlistPanelVideoRenderer', {})
        if not p:
            continue
        vid = p.get('videoId')
        if not vid or vid in seen or len(vid) != 11:
            continue

        title_runs = p.get('title', {}).get('runs', [])
        title = sanitize_text(''.join(r.get('text', '') for r in title_runs))
        if not title:
            continue

        # Extract artist preferentially from shortBylineText, then longBylineText
        short_runs = p.get('shortBylineText', {}).get('runs', [])
        artist = sanitize_text(''.join(r.get('text', '') for r in short_runs))
        if not artist:
            long_runs = p.get('longBylineText', {}).get('runs', [])
            byline = sanitize_text(''.join(r.get('text', '') for r in long_runs))
            artist = byline.split(' • ')[0].strip() if ' • ' in byline else byline

        length_runs = p.get('lengthText', {}).get('runs', [])
        duration = sanitize_text(''.join(r.get('text', '') for r in length_runs))

        seen.add(vid)
        results.append({
            'id': vid,
            'title': title,
            'artist': artist or 'YouTube Music',
            'duration': duration or '',
            'thumbnail': f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"
        })
        if len(results) >= limit:
            break

    return results

# ----------------------------------------------------------------------
# MPV Daemon & Single-Instance Process Management
# ----------------------------------------------------------------------
def get_running_mpv_pids():
    try:
        out = subprocess.check_output(
            ["pgrep", "-u", str(UID), "-f", "music-flow-ytmusic"],
            text=True
        )
        return [int(p.strip()) for p in out.splitlines() if p.strip()]
    except Exception:
        return []

def cleanup_duplicate_mpv(keep_pid=None):
    """Kills any duplicate or rogue mpv instances except keep_pid."""
    pids = get_running_mpv_pids()
    for p in pids:
        if keep_pid and p == keep_pid:
            continue
        try:
            os.kill(p, 9)
        except Exception:
            pass

def get_mpv_socket():
    # 1. Check if existing socket is active and responsive
    if os.path.exists(SOCKET_PATH):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(2.5)
            s.connect(SOCKET_PATH)
            s.sendall(b'{"command": ["get_property", "pid"]}\n')
            res = s.recv(1024)
            if b'"error":"success"' in res:
                try:
                    data = json.loads(res.decode('utf-8'))
                    active_pid = data.get("data")
                    if active_pid:
                        cleanup_duplicate_mpv(keep_pid=active_pid)
                except Exception:
                    pass
                return s
            s.close()
        except Exception:
            pass

    # 2. If socket is unconnectable, kill all dead plugin mpv processes
    cleanup_duplicate_mpv(keep_pid=None)
    if os.path.exists(SOCKET_PATH):
        try:
            os.remove(SOCKET_PATH)
        except Exception:
            pass

    # 3. Launch single background mpv daemon
    cmd = [
        "mpv",
        "--no-video",
        "--idle=yes",
        f"--input-ipc-server={SOCKET_PATH}",
        "--script=/usr/lib/mpv-mpris/mpris.so",
        "--ytdl-format=bestaudio/best",
        "--ytdl-raw-options=extractor-args=youtube:player_client=android",
        "--volume=100",
        "--keep-open=no"
    ]

    subprocess.Popen(
        cmd,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )

    for _ in range(40):
        time.sleep(0.1)
        if os.path.exists(SOCKET_PATH):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(2.5)
                s.connect(SOCKET_PATH)
                return s
            except Exception:
                pass
    return None

def send_mpv_cmd(command, timeout=3.0):
    s = get_mpv_socket()
    if not s:
        return {"error": "failed to connect to mpv"}
    try:
        s.settimeout(timeout)
        payload = json.dumps({"command": command}) + "\n"
        s.sendall(payload.encode("utf-8"))
        res = b""
        while not res.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            res += chunk
        s.close()
        for line in res.decode("utf-8", errors="ignore").splitlines():
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                try:
                    data = json.loads(line)
                    if "error" in data:
                        return data
                except Exception:
                    continue
        return {"status": "ok"}
    except Exception as e:
        if s:
            try:
                s.close()
            except Exception:
                pass
        return {"error": str(e)}

# ----------------------------------------------------------------------
# Background Radio Population Worker
# ----------------------------------------------------------------------
def populate_radio_worker(video_id, title="", artist=""):
    """Background task: fetches YouTube Music radio tracks and appends them to mpv."""
    try:
        radio_tracks = get_radio_tracks(video_id, limit=20)
        if not radio_tracks:
            return

        s = get_mpv_socket()
        if s:
            for track in radio_tracks:
                url = f"https://www.youtube.com/watch?v={track['id']}"
                cmd = json.dumps({"command": ["loadfile", url, "append"]}) + "\n"
                s.sendall(cmd.encode("utf-8"))
                try:
                    s.recv(1024)
                except Exception:
                    pass
            s.close()

        # Update cache with authentic radio metadata
        current_cache = load_queue_cache()
        existing_ids = {item.get('id') for item in current_cache}
        for track in radio_tracks:
            if track['id'] not in existing_ids:
                current_cache.append(track)
                existing_ids.add(track['id'])
        save_queue_cache(current_cache)
    except Exception:
        pass

# ----------------------------------------------------------------------
# Playback & Queue Control
# ----------------------------------------------------------------------
def play(vid, title="", artist=""):
    direct_id = extract_video_id(vid) or vid
    if not direct_id or len(direct_id) != 11:
        return {"error": "invalid video id"}

    # 1. Kill any existing radio worker for previously playing song
    try:
        subprocess.run(
            ["pkill", "-9", "-u", str(UID), "-f", "populate-radio"],
            stderr=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL
        )
    except Exception:
        pass

    s = get_mpv_socket()
    if not s:
        return {"error": "failed to launch mpv"}

    try:
        url = f"https://www.youtube.com/watch?v={direct_id}"
        # 2. Replace current playing track & clear existing queue
        s.sendall(json.dumps({"command": ["playlist-clear"]}).encode("utf-8") + b"\n")
        try:
            s.recv(1024)
        except Exception:
            pass

        load_cmd = json.dumps({"command": ["loadfile", url, "replace"]}) + "\n"
        s.sendall(load_cmd.encode("utf-8"))
        try:
            s.recv(1024)
        except Exception:
            pass

        # 3. Clean title & artist
        clean_t = sanitize_text(title)
        clean_a = sanitize_text(artist)
        if not clean_t:
            resolved_t, resolved_a = resolve_oembed_metadata(direct_id)
            clean_t = resolved_t
            clean_a = clean_a or resolved_a

        if clean_t:
            full_title = f"{clean_a} - {clean_t}" if (clean_a and clean_a not in clean_t) else clean_t
            title_cmd = json.dumps({"command": ["set_property", "force-media-title", full_title]}) + "\n"
            s.sendall(title_cmd.encode("utf-8"))
            try:
                s.recv(1024)
            except Exception:
                pass
        else:
            title_cmd = json.dumps({"command": ["set_property", "force-media-title", ""]}) + "\n"
            s.sendall(title_cmd.encode("utf-8"))
            try:
                s.recv(1024)
            except Exception:
                pass

        # 4. Unpause
        pause_cmd = json.dumps({"command": ["set_property", "pause", False]}) + "\n"
        s.sendall(pause_cmd.encode("utf-8"))
        try:
            s.recv(1024)
        except Exception:
            pass

        # 5. Initialize queue cache with ONLY this song
        current_track = {
            'id': direct_id,
            'title': clean_t or f"YouTube Track ({direct_id})",
            'artist': clean_a or "YouTube Music",
            'duration': '',
            'thumbnail': f"https://i.ytimg.com/vi/{direct_id}/hqdefault.jpg"
        }
        save_queue_cache([current_track])
        s.close()

        # 6. Spawn background radio automix queue generator
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "populate-radio", direct_id, clean_t, clean_a],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

        return {"status": "ok", "id": direct_id}
    except Exception as e:
        if s:
            try:
                s.close()
            except Exception:
                pass
        return {"error": str(e)}

def queue_song(vid, title="", artist="", duration=""):
    direct_id = extract_video_id(vid) or vid
    if not direct_id or len(direct_id) != 11:
        return {"error": "invalid video id"}

    clean_t = sanitize_text(title)
    clean_a = sanitize_text(artist)
    if not clean_t:
        resolved_t, resolved_a = resolve_oembed_metadata(direct_id)
        clean_t = resolved_t
        clean_a = clean_a or resolved_a

    url = f"https://www.youtube.com/watch?v={direct_id}"
    res = send_mpv_cmd(["loadfile", url, "append"])

    # Update cache
    cache = load_queue_cache()
    track_item = {
        'id': direct_id,
        'title': clean_t or f"Track ({direct_id})",
        'artist': clean_a or "YouTube Music",
        'duration': sanitize_text(duration),
        'thumbnail': f"https://i.ytimg.com/vi/{direct_id}/hqdefault.jpg"
    }
    cache.append(track_item)
    save_queue_cache(cache)

    return {"status": "ok", "id": direct_id, "title": clean_t}

def get_queue():
    res = send_mpv_cmd(["get_property", "playlist"])
    mpv_playlist = res.get("data", [])
    if not isinstance(mpv_playlist, list):
        return {"currentIndex": -1, "count": 0, "items": []}

    cache = load_queue_cache()
    cache_by_id = {item.get('id'): item for item in cache if isinstance(item, dict) and item.get('id')}

    items = []
    current_idx = -1
    needs_cache_save = False

    for i, entry in enumerate(mpv_playlist):
        vid = extract_video_id(entry.get("filename", ""))
        is_cur = bool(entry.get("current", False))
        is_playing = bool(entry.get("playing", False))
        if is_cur:
            current_idx = i

        meta = cache_by_id.get(vid, {})
        title = meta.get("title") or entry.get("title")
        artist = meta.get("artist") or "YouTube Music"
        duration = meta.get("duration") or ""
        thumb = meta.get("thumbnail") or (f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg" if vid else "")

        # If title is missing or a placeholder like "Track ...", resolve it via oembed
        if vid and (not title or title.startswith("Track ") or title.startswith("watch?v=")):
            resolved_t, resolved_a = resolve_oembed_metadata(vid)
            if resolved_t:
                title = resolved_t
                if not artist or artist == "YouTube Music":
                    artist = resolved_a or artist
                meta['id'] = vid
                meta['title'] = title
                meta['artist'] = artist
                cache_by_id[vid] = meta
                needs_cache_save = True

        if not title:
            title = f"YouTube Music Track"

        items.append({
            "index": i,
            "id": vid or "",
            "title": html.unescape(title),
            "artist": html.unescape(artist),
            "duration": duration,
            "thumbnail": thumb,
            "current": is_cur,
            "playing": is_playing
        })

    if needs_cache_save:
        save_queue_cache(list(cache_by_id.values()))

    return {
        "currentIndex": current_idx,
        "count": len(items),
        "items": items
    }

def play_index(index):
    try:
        idx = int(index)
    except Exception:
        return {"error": "invalid index"}

    # Check if mpv playlist has items
    q = send_mpv_cmd(["get_property", "playlist"])
    pl = q.get("data", [])
    if isinstance(pl, list) and 0 <= idx < len(pl):
        send_mpv_cmd(["set_property", "force-media-title", ""])
        res = send_mpv_cmd(["playlist-play-index", idx])
        send_mpv_cmd(["set_property", "pause", False])
        return res

    # Otherwise reload from cached queue
    cache = load_queue_cache()
    if 0 <= idx < len(cache):
        target = cache[idx]
        return play(target.get("id"), target.get("title", ""), target.get("artist", ""))

    return {"error": "index out of range"}

def remove_index(index):
    try:
        idx = int(index)
    except Exception:
        return {"error": "invalid index"}

    res = send_mpv_cmd(["playlist-remove", idx])
    # Update cache by removing corresponding item
    cache = load_queue_cache()
    if 0 <= idx < len(cache):
        cache.pop(idx)
        save_queue_cache(cache)
    return res

def clear_queue():
    res = send_mpv_cmd(["playlist-clear"])
    # Keep only currently playing song in cache
    q = get_queue()
    cur_idx = q.get("currentIndex", 0)
    items = q.get("items", [])
    if items and 0 <= cur_idx < len(items):
        save_queue_cache([items[cur_idx]])
    else:
        save_queue_cache([])
    return res

def seek_to(seconds):
    try:
        sec = float(seconds)
        return send_mpv_cmd(["seek", sec, "absolute"])
    except Exception as e:
        return {"error": str(e)}

# ----------------------------------------------------------------------
# CLI Interface
# ----------------------------------------------------------------------
def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "missing command"}))
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "search":
        query = sys.argv[2] if len(sys.argv) > 2 else ""
        results = search(query)
        print(json.dumps(results))
    elif cmd == "play":
        vid = sys.argv[2] if len(sys.argv) > 2 else ""
        title = sys.argv[3] if len(sys.argv) > 3 else ""
        artist = sys.argv[4] if len(sys.argv) > 4 else ""
        res = play(vid, title, artist)
        print(json.dumps(res))
    elif cmd == "populate-radio":
        vid = sys.argv[2] if len(sys.argv) > 2 else ""
        title = sys.argv[3] if len(sys.argv) > 3 else ""
        artist = sys.argv[4] if len(sys.argv) > 4 else ""
        populate_radio_worker(vid, title, artist)
        print(json.dumps({"status": "populated"}))
    elif cmd == "queue":
        vid = sys.argv[2] if len(sys.argv) > 2 else ""
        title = sys.argv[3] if len(sys.argv) > 3 else ""
        artist = sys.argv[4] if len(sys.argv) > 4 else ""
        duration = sys.argv[5] if len(sys.argv) > 5 else ""
        res = queue_song(vid, title, artist, duration)
        print(json.dumps(res))
    elif cmd == "get-queue":
        res = get_queue()
        print(json.dumps(res))
    elif cmd == "play-index":
        index = sys.argv[2] if len(sys.argv) > 2 else "0"
        res = play_index(index)
        print(json.dumps(res))
    elif cmd == "remove-index":
        index = sys.argv[2] if len(sys.argv) > 2 else "0"
        res = remove_index(index)
        print(json.dumps(res))
    elif cmd == "clear-queue":
        res = clear_queue()
        print(json.dumps(res))
    elif cmd == "seek":
        target = sys.argv[2] if len(sys.argv) > 2 else "0"
        res = seek_to(target)
        print(json.dumps(res))
    elif cmd == "stop" or cmd == "pause":
        res = send_mpv_cmd(["set_property", "pause", True])
        print(json.dumps(res))
    elif cmd == "next":
        send_mpv_cmd(["set_property", "force-media-title", ""])
        res = send_mpv_cmd(["playlist-next"])
        print(json.dumps(res))
    elif cmd == "prev":
        send_mpv_cmd(["set_property", "force-media-title", ""])
        res = send_mpv_cmd(["playlist-prev"])
        print(json.dumps(res))
    else:
        print(json.dumps({"error": f"unknown command: {cmd}"}))
        sys.exit(1)

if __name__ == "__main__":
    main()
