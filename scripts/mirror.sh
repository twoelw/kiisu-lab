#!/usr/bin/env sh
set -eu

# Mirrors latest release assets (tgz + dfu) and metadata for a set of GitHub repos
# into the nginx web root so the SPA can fetch from same-origin without CORS.
#
# Config via env:
#   MIRROR_REPOS: space-separated list like "owner1/repo1 owner2/repo2"
#   MIRROR_ROOT:  absolute path to nginx web root (default: /usr/share/nginx/html)
#   GITHUB_TOKEN: optional token to avoid rate limiting
#   USER_AGENT:   UA string for GitHub API

MIRROR_REPOS=${MIRROR_REPOS:-"kiisu-io/kiisu-firmware Next-Flip/Momentum-Firmware noproto/xero-firmware"}
MIRROR_ROOT=${MIRROR_ROOT:-"/usr/share/nginx/html"}
USER_AGENT=${USER_AGENT:-"kiisu-lab-mirror"}
MIRROR_MOMENTUM_CHANNEL=${MIRROR_MOMENTUM_CHANNEL:-"wip-kiisu-mntm"}

gh_get() {
  url="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -sS -L \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: ${USER_AGENT}" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  else
    curl -sS -L \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: ${USER_AGENT}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  fi
}

# GET with ETag cache: writes body to $3 (cache path) only when changed; honors If-None-Match
gh_get_cached() {
  url="$1"; etag_file="$2"; cache_file="$3"
  tmp_h="$(mktemp)"; tmp_b="$(mktemp)"
  if [ -f "$etag_file" ]; then
    etag=$(cat "$etag_file" 2>/dev/null || true)
  else
    etag=""
  fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    if [ -n "$etag" ]; then
      curl -sS -L -D "$tmp_h" -o "$tmp_b" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ${USER_AGENT}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "If-None-Match: $etag" \
        "$url" >/dev/null
    else
      curl -sS -L -D "$tmp_h" -o "$tmp_b" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ${USER_AGENT}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$url" >/dev/null
    fi
  else
    if [ -n "$etag" ]; then
      curl -sS -L -D "$tmp_h" -o "$tmp_b" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ${USER_AGENT}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "If-None-Match: $etag" \
        "$url" >/dev/null
    else
      curl -sS -L -D "$tmp_h" -o "$tmp_b" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ${USER_AGENT}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$url" >/dev/null
    fi
  fi
  code=$(head -n1 "$tmp_h" | awk '{print $2}')
  if [ "$code" = "304" ] && [ -f "$cache_file" ]; then
    # Unchanged
    rm -f "$tmp_h" "$tmp_b"
    return 0
  elif [ "$code" = "200" ]; then
    # Update cache and ETag
    # Try strong ETag first then weak
    new_etag=$(awk 'tolower($1)=="etag:"{print $2}' "$tmp_h" | tr -d '\r')
    if [ -n "$new_etag" ]; then
      printf '%s' "$new_etag" > "$etag_file"
    fi
    mv -f "$tmp_b" "$cache_file"
    rm -f "$tmp_h"
    return 0
  else
    # Unexpected status; keep old cache if present
    rm -f "$tmp_h" "$tmp_b"
    return 1
  fi
}

sha256_file() {
  # Works with busybox sha256sum
  sha256sum "$1" | awk '{print $1}'
}

ensure_dir() {
  dir="$1"
  mkdir -p "$dir"
}

latest_tag_via_redirect() {
  repo="$1"
  # Follow redirects and capture the final URL; GitHub redirects /releases/latest -> /releases/tag/<tag>
  final=$(curl -sS -L -o /dev/null -w '%{url_effective}' -H "User-Agent: ${USER_AGENT}" "https://github.com/${repo}/releases/latest" 2>/dev/null || true)
  # Extract tag from final URL
  printf '%s' "$final" | sed -n 's#.*/releases/tag/\(.*\)$#\1#p'
}

# Momentum-specific logic (must be defined before usage)
mirror_momentum() {
  base_dir="$1"
  ensure_dir "$base_dir"
  feed_url="https://up.momentum-fw.dev/firmware/directory.json"

  tmp_json="${base_dir}/momentum.upstream.json"
  echo "[mirror] momentum: fetching directory.json"
  # ETag for momentum feed
  etag_file="${base_dir}/momentum.etag"
  hdr_tmp="$(mktemp)"; body_tmp="$(mktemp)"
  if [ -f "$etag_file" ]; then
    etag=$(cat "$etag_file" 2>/dev/null || true)
  else
    etag=""
  fi
  if [ -n "$etag" ]; then
    curl -sS -L -D "$hdr_tmp" -o "$body_tmp" -H "User-Agent: ${USER_AGENT}" -H "If-None-Match: $etag" "$feed_url" >/dev/null
  else
    curl -sS -L -D "$hdr_tmp" -o "$body_tmp" -H "User-Agent: ${USER_AGENT}" "$feed_url" >/dev/null
  fi
  code=$(head -n1 "$hdr_tmp" | awk '{print $2}')
  if [ "$code" = "304" ] && [ -f "$tmp_json" ]; then
    : # unchanged
    rm -f "$hdr_tmp" "$body_tmp"
  elif [ "$code" = "200" ]; then
    new_etag=$(awk 'tolower($1)=="etag:"{print $2}' "$hdr_tmp" | tr -d '\r')
    if [ -n "$new_etag" ]; then printf '%s' "$new_etag" > "$etag_file"; fi
    mv -f "$body_tmp" "$tmp_json"
    rm -f "$hdr_tmp"
  else
    rm -f "$hdr_tmp" "$body_tmp"
    # If fetch fails but we have previous file, continue
  fi

  directory_json=$(cat "$tmp_json" 2>/dev/null || printf '{}')

  # Helper: download one file if missing; compute sha256
  m_dl() {
    url="$1"; out="$2"
    if [ ! -f "$out" ]; then
  echo "[mirror] momentum: downloading $(basename "$out")" 1>&2
      curl -sS -L -o "$out.tmp" -H "User-Agent: ${USER_AGENT}" "$url"
      mv -f "$out.tmp" "$out"
    fi
    sha256_file "$out"
  }

  # Build one channel based on preferred Momentum channel
  make_channel() {
    channel_id="$1"
    title="$2"
    # Extract first version entry
    ver=$(printf '%s' "$directory_json" | jq -r ".channels[] | select(.id==\"$channel_id\") | .versions[0].version // \"\"")
    [ -z "$ver" ] && return 0
    body=$(printf '%s' "$directory_json" | jq -r ".channels[] | select(.id==\"$channel_id\") | .versions[0].changelog // \"\"")
    ts=$(printf '%s' "$directory_json" | jq -r ".channels[] | select(.id==\"$channel_id\") | .versions[0].timestamp // 0")
    files_json=$(printf '%s' "$directory_json" | jq -r ".channels[] | select(.id==\"$channel_id\") | .versions[0].files")

    out_tag_dir="${base_dir}/${ver}"
    ensure_dir "$out_tag_dir"
    # Build a list of all relevant assets (update_tgz and dfu/full_dfu for f7/f18)
    files_meta="${out_tag_dir}/files.meta.json"
    printf '[]' > "$files_meta"

    # Accumulate candidates as JSON objects, then loop per object to download
    printf '%s\n' "$files_json" \
      | jq -c '[.[] | select((.type=="update_tgz" or .type=="full_dfu" or .type=="dfu") and (.target=="f7" or .target=="f18")) | {url, target, type: (if .type=="update_tgz" then "update_tgz" else "dfu" end)}] | .[]' \
      | while read -r item; do
          url=$(printf '%s' "$item" | jq -r '.url // empty')
          target=$(printf '%s' "$item" | jq -r '.target // empty')
          type=$(printf '%s' "$item" | jq -r '.type // empty')
          [ -n "$url" ] || continue
          name=$(basename "$url")
          sha=$(m_dl "$url" "${out_tag_dir}/${name}")
          path="/mirror/Next-Flip/Momentum-Firmware/${ver}/${name}"
          jq --arg url "$path" --arg type "$type" --arg target "$target" --arg sha "$sha" \
             '. + [{url:$url, type:$type, target:$target, sha256:$sha}]' "$files_meta" > "${files_meta}.tmp" && mv -f "${files_meta}.tmp" "$files_meta"
        done

    # Build channel JSON for momentum (using accumulated files)
    jq -n \
      --arg id "distro:momentum" \
      --arg title "$title" \
      --arg desc "Momentum Firmware" \
      --arg repoUrl "https://up.momentum-fw.dev/firmware" \
      --arg ver "$ver" \
      --arg body "$body" \
      --argjson ts ${ts:-0} \
      --slurpfile files "$files_meta" \
      '{
        id: $id,
        title: $title,
        description: $desc,
        versions: [
          {
            version: $ver,
            timestamp: ($ts | tonumber),
            changelog: $body,
            files: $files[0]
          }
        ],
        repoUrl: $repoUrl,
        distroId: "momentum"
      }' > "${base_dir}/channel.local.json"

    # Also synthesize a minimal release.local.json from the first tgz/dfu for compatibility
    first_tgz=$(jq -r '[.[] | select(.type=="update_tgz")][0].url // ""' "$files_meta")
    first_dfu=$(jq -r '[.[] | select(.type=="dfu")][0].url // ""' "$files_meta")
    first_tgz_name=$(basename "${first_tgz:-}")
    first_dfu_name=$(basename "${first_dfu:-}")
    jq -n \
      --arg ver "$ver" \
      --arg body "$body" \
      --arg tgz_name "$first_tgz_name" \
      --arg tgz_url "$first_tgz" \
      --arg dfu_name "$first_dfu_name" \
      --arg dfu_url "$first_dfu" \
      --argjson ts ${ts:-0} \
      '{
        tag_name: $ver,
        name: $ver,
        published_at: ($ts/1000 | floor | todate),
        body: $body,
        assets: ([
          (if $tgz_name != "" then { name: $tgz_name, browser_download_url: $tgz_url } else empty end),
          (if $dfu_name != "" then { name: $dfu_name, browser_download_url: $dfu_url } else empty end)
        ])
      }' > "${base_dir}/release.local.json"
  }

  # Pick only the preferred channel; never fall back
  prefer="$MIRROR_MOMENTUM_CHANNEL"
  if [ -n "$prefer" ] && printf '%s' "$directory_json" | jq -e ".channels[]? | select(.id==\"$prefer\")" >/dev/null 2>&1; then
    case "$prefer" in
      wip-kiisu-mntm) make_channel "wip-kiisu-mntm" "Momentum Kiisu Branch" ;;
      release) make_channel "release" "Momentum by Next-Flip" ;;
      development) make_channel "development" "Momentum (Development)" ;;
      *) make_channel "$prefer" "Momentum" ;;
    esac
  else
    echo "[mirror] momentum: preferred channel '$prefer' not found; skipping" >&2
  fi
}

mirror_repo() {
  repo="$1" # owner/name
  owner=$(printf '%s' "$repo" | cut -d'/' -f1)
  name=$(printf '%s' "$repo" | cut -d'/' -f2)

  base_dir="${MIRROR_ROOT}/mirror/${owner}/${name}"
  ensure_dir "$base_dir"

  # Special-case: Momentum moved off GitHub to its own update feed
  if [ "$repo" = "Next-Flip/Momentum-Firmware" ]; then
    mirror_momentum "$base_dir" || echo "[mirror] momentum mirror failed" >&2
    return 0
  fi

  # Quick check: detect latest tag via HTML redirect (not API, no API rate limit)
  quick_tag=$(latest_tag_via_redirect "$repo" || true)
  state_tag_file="${base_dir}/last_tag"
  if [ -f "$state_tag_file" ]; then
    last_tag=$(cat "$state_tag_file" 2>/dev/null || true)
  else
    last_tag=""
  fi
  # Even if tag seems unchanged, continue to rebuild channel JSON using cached metadata.

  # Fetch metadata with ETag caching
  gh_get_cached "https://api.github.com/repos/${repo}/releases/latest" "${base_dir}/release.etag" "${base_dir}/release.upstream.json" || true
  gh_get_cached "https://api.github.com/repos/${repo}" "${base_dir}/repo.etag" "${base_dir}/repo.json" || true
  release_json=$(cat "${base_dir}/release.upstream.json" 2>/dev/null || printf '{}')
  repo_json=$(cat "${base_dir}/repo.json" 2>/dev/null || printf '{}')

  # Extract fields
  tag=$(printf '%s' "$release_json" | jq -r '(.tag_name // .name // "")')
  [ -z "$tag" ] && echo "[mirror] ${repo}: no tag found, skipping" && return 0

  # Strip leading v for version
  plain_tag=$(printf '%s' "$tag" | sed -e 's/^v//')

  # State check: skip if already mirrored
  # last_tag already loaded above; proceed

  # Locate assets (first matching tgz/dfu with 'kiisu_' prefix)
  tgz_name=$(printf '%s' "$release_json" | jq -r '[.assets[]? | select((.name? // "") | test("^kiisu_.*\\.tgz$"; "i"))][0].name // ""')
  tgz_url=$(printf '%s' "$release_json" | jq -r '[.assets[]? | select((.name? // "") | test("^kiisu_.*\\.tgz$"; "i"))][0].browser_download_url // ""')
  dfu_name=$(printf '%s' "$release_json" | jq -r '[.assets[]? | select((.name? // "") | test("^kiisu_.*\\.dfu$"; "i"))][0].name // ""')
  dfu_url=$(printf '%s' "$release_json" | jq -r '[.assets[]? | select((.name? // "") | test("^kiisu_.*\\.dfu$"; "i"))][0].browser_download_url // ""')

  tag_dir="${base_dir}/${tag}"
  ensure_dir "$tag_dir"

  # Only download when new tag appears (or files missing)
  if [ "$tag" != "$last_tag" ]; then
    echo "[mirror] ${repo}: new tag ${tag} (prev: ${last_tag:-none})"
  fi

  tgz_path=""; tgz_sha=""; tgz_size=0
  if [ -n "$tgz_name" ] && [ -n "$tgz_url" ]; then
    local_tgz="${tag_dir}/${tgz_name}"
    if [ "$tag" != "$last_tag" ] || [ ! -f "$local_tgz" ]; then
      echo "[mirror] ${repo}: downloading ${tgz_name}"
      curl -sS -L -o "$local_tgz.tmp" -H "User-Agent: ${USER_AGENT}" "$tgz_url"
      mv -f "$local_tgz.tmp" "$local_tgz"
    fi
    tgz_path="/mirror/${owner}/${name}/${tag}/${tgz_name}"
    tgz_sha=$(sha256_file "$local_tgz")
    tgz_size=$(wc -c < "$local_tgz" | tr -d ' ')
  fi

  dfu_path=""; dfu_sha=""; dfu_size=0
  if [ -n "$dfu_name" ] && [ -n "$dfu_url" ]; then
    local_dfu="${tag_dir}/${dfu_name}"
    if [ "$tag" != "$last_tag" ] || [ ! -f "$local_dfu" ]; then
      echo "[mirror] ${repo}: downloading ${dfu_name}"
      curl -sS -L -o "$local_dfu.tmp" -H "User-Agent: ${USER_AGENT}" "$dfu_url"
      mv -f "$local_dfu.tmp" "$local_dfu"
    fi
    dfu_path="/mirror/${owner}/${name}/${tag}/${dfu_name}"
    dfu_sha=$(sha256_file "$local_dfu")
    dfu_size=$(wc -c < "$local_dfu" | tr -d ' ')
  fi

  # Build a local release JSON with only the mirrored assets and local URLs
  printf '%s' "$release_json" | jq -n \
    --argjson upstream "$release_json" \
    --arg tgz_name "$tgz_name" \
    --arg tgz_path "$tgz_path" \
    --arg tgz_sha "$tgz_sha" \
    --argjson tgz_size ${tgz_size:-0} \
    --arg dfu_name "$dfu_name" \
    --arg dfu_path "$dfu_path" \
    --arg dfu_sha "$dfu_sha" \
    --argjson dfu_size ${dfu_size:-0} \
    '(
      $upstream | {
        tag_name, name, published_at, body,
        assets: ([
          (if $tgz_name != "" then { name: $tgz_name, browser_download_url: $tgz_path, content_type: "application/octet-stream", size: $tgz_size, sha256: $tgz_sha } else empty end),
          (if $dfu_name != "" then { name: $dfu_name, browser_download_url: $dfu_path, content_type: "application/octet-stream", size: $dfu_size, sha256: $dfu_sha } else empty end)
        ])
      }
    )' > "${base_dir}/release.local.json"

  # Update last_tag and a compact channel summary for this repo
  printf '%s' "$tag" > "$state_tag_file"

  # Derive display title and repoUrl (best-effort constants)
  case "$repo" in
    kiisu-io/kiisu-firmware)
      ch_title="Official Kiisu Firmware by Kiisu Team";
      distro_id="kiisu-official";
      repo_url="https://github.com/kiisu-io/kiisu-firmware";
      ;;
    Next-Flip/Momentum-Firmware)
      ch_title="Momentum by Next-Flip";
      distro_id="momentum";
      repo_url="https://github.com/Next-Flip/Momentum-Firmware";
      ;;
    noproto/xero-firmware)
      ch_title="Xero by Notopro";
      distro_id="xero";
      repo_url="https://github.com/noproto/xero-firmware";
      ;;
    *)
      ch_title="$name";
      distro_id="$name";
      repo_url="https://github.com/${repo}";
      ;;
  esac

  repo_desc=$(printf '%s' "$repo_json" | jq -r '.description // ""')
  # milliseconds since epoch for UI compatibility
  published_ms=$(printf '%s' "$release_json" | jq -r 'if .published_at then ((.published_at | fromdateiso8601) * 1000 | tostring) else ((now * 1000) | tostring) end')

  # Infer target from filename (best effort)
  infer_target() {
    fname="$1"
    # Extract exactly f + 1-2 digits (e.g., f7, f18); ignore trailing chars
    match=$(printf '%s' "$fname" | sed -n 's/.*\(f[0-9]\{1,2\}\).*/\1/p' | head -n1)
    printf '%s' "$match"
  }
  tgz_target=$(infer_target "$tgz_name"); [ -z "$tgz_target" ] && tgz_target="f7"
  dfu_target=$(infer_target "$dfu_name"); [ -z "$dfu_target" ] && dfu_target="f7"

  channel_json=$(jq -n \
    --arg id "distro:${distro_id}" \
    --arg title "$ch_title" \
    --arg desc "$repo_desc" \
    --arg repoUrl "$repo_url" \
    --arg ver "$plain_tag" \
    --arg body "$(printf '%s' "$release_json" | jq -r '.body // ""')" \
    --arg tgz_url "$tgz_path" \
    --arg tgz_target "$tgz_target" \
    --arg tgz_sha "$tgz_sha" \
    --arg dfu_url "$dfu_path" \
    --arg dfu_target "$dfu_target" \
    --arg dfu_sha "$dfu_sha" \
    --argjson ts ${published_ms:-0} \
    '
    {
      id: $id,
      title: $title,
      description: $desc,
      versions: [
        {
          version: $ver,
          timestamp: ($ts | tonumber),
          changelog: $body,
          files: ([
            (if $tgz_url != "" then { url: $tgz_url, type: "update_tgz", target: $tgz_target, sha256: $tgz_sha } else empty end),
            (if $dfu_url != "" then { url: $dfu_url, type: "dfu", target: $dfu_target, sha256: $dfu_sha } else empty end)
          ])
        }
      ],
      repoUrl: $repoUrl,
      distroId: ($id | sub("^distro:"; ""))
    }')

  printf '%s' "$channel_json" > "${base_dir}/channel.local.json"
}

aggregate_channels() {
  out_dir="${MIRROR_ROOT}/mirror"
  ensure_dir "$out_dir"
  # Collect all channel.local.json files into a Channel[]
  find "$out_dir" -type f -name 'channel.local.json' -print0 \
    | xargs -0 -I {} sh -c 'cat "$1"' -- {} \
    | jq -s '.' > "${out_dir}/channels.json" || printf '[]' > "${out_dir}/channels.json"
}

main() {
  for repo in $MIRROR_REPOS; do
    mirror_repo "$repo" || echo "[mirror] failed for $repo" >&2
  done
  aggregate_channels
}

main "$@"
