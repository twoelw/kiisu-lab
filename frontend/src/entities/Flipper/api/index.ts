import { instance } from 'boot/axios'
import { unpack, ungzip } from 'shared/lib/utils/operation'
import type { Channel } from '../model/types'

// Minimal typings for GitHub Releases API objects we use
type GitHubAsset = {
  name?: string
  browser_download_url?: string
  id?: number
  content_type?: string
  size?: number
  sha256?: string
}

type GitHubRelease = {
  tag_name?: string
  name?: string
  published_at?: string
  body?: string
  assets?: GitHubAsset[]
}

// Build a same-origin proxy URL to bypass browser CORS when fetching GitHub assets
function makeGithubProxyUrl(rawUrl: string): string {
  try {
    const u = new URL(rawUrl)
    const host = u.hostname
    const isGithubAssetHost =
      host.endsWith('github.com') || host.endsWith('githubusercontent.com')
    // Only proxy known GitHub hosts; otherwise, return as-is
    if (!isGithubAssetHost) return rawUrl
  } catch {
    return rawUrl
  }
  // Same-origin dev proxy endpoint implemented in quasar.config.ts
  const origin = typeof location !== 'undefined' ? location.origin : ''
  return `${origin}/github-asset?url=${encodeURIComponent(rawUrl)}`
}

// Build a same-origin mirror URL for a repo asset if the mirror job ran on the server.
function makeMirrorAssetUrl(ownerRepo: string, tag: string, filename: string): string {
  const [owner, name] = ownerRepo.split('/')
  const origin = typeof location !== 'undefined' ? location.origin : ''
  return `${origin}/mirror/${owner}/${name}/${tag}/${filename}`
}

async function tryFetch<T>(url: string): Promise<T | undefined> {
  try {
    const { data } = await instance.get<T>(url, { withCredentials: false })
    return data
  } catch {
    return undefined
  }
}

async function fetchLatestReleaseJson(repo: string): Promise<GitHubRelease> {
  // Prefer same-origin mirrored JSON if available
  const [owner, name] = repo.split('/')
  const origin = typeof location !== 'undefined' ? location.origin : ''
  const mirrorUrl = `${origin}/mirror/${owner}/${name}/release.local.json`
  const mirrored = await tryFetch<GitHubRelease>(mirrorUrl)
  if (mirrored) return mirrored
  // No fallback: treat as unavailable
  throw new Error('mirrored release not available')
}

async function fetchChannels(/* target: string */): Promise<Channel[]> {
  // Build channels from configured distros only
  const channels: Channel[] = []
  const origin = typeof location !== 'undefined' ? location.origin : ''
  // Prefer server-built aggregate when available
  const mirrorChannels = await tryFetch<Channel[]>(`${origin}/mirror/channels.json`)
  if (mirrorChannels && Array.isArray(mirrorChannels) && mirrorChannels.length) {
    channels.push(...mirrorChannels)
  }
  if (!channels.length) {
    throw new Error('no mirrored channels available')
  }

  // Append custom channel if provided via URL params
  const params = new URLSearchParams(location.search)
  const customSource = {
    url: params.get('url'),
    channel: params.get('channel'),
    version: params.get('version'),
    target: params.get('target')
  }

  if (customSource.url) {
    channels.push({
      id: 'custom',
      title: customSource.channel || 'Custom',
  description: 'Custom firmware source',
      versions: [
        {
          version: customSource.version || 'unknown',
          timestamp: Date.now(),
          changelog: '',
          files: [
            {
              url: makeGithubProxyUrl(customSource.url),
              type: 'update_tgz',
              target: customSource.target || 'f7',
              sha256: ''
            }
          ]
        }
      ]
    })
  }

  return channels
}

async function fetchRegions() {
  return await instance
    .get('https://update.flipperzero.one/regions/api/v0/bundle')
    .then(({ data }) => {
      if (data.error) {
        throw new Error(data.error.text)
      } else if (data.success) {
        return data.success
      }
    })
    .catch(({ status }) => {
      if (status >= 400) {
        throw new Error('Failed to fetch region (' + status + ')')
      }
    })
}

async function fetchFirmware(url: string) {
  // Use fetch to avoid axios default headers causing CORS preflight on GitHub assets
  try {
  const res = await fetch(url, {
      method: 'GET',
      mode: 'cors',
      credentials: 'omit',
      // Avoid sending Content-Type on GET
      headers: {}
    })
    if (!res.ok) {
      throw new Error('Failed to fetch firmware (' + res.status + ')')
    }
    const data = await res.arrayBuffer()
    return unpack(data)
    } catch {
      throw new Error('Failed to fetch firmware (network)')
  }
}

async function fetchFirmwareTar(url: string) {
  // Use fetch to avoid axios default headers causing CORS preflight on GitHub assets
  try {
  const res = await fetch(url, {
      method: 'GET',
      mode: 'cors',
      credentials: 'omit',
      headers: {}
    })
    if (!res.ok) {
      throw new Error('Failed to fetch firmware (' + res.status + ')')
    }
    const data = await res.arrayBuffer()
    return ungzip(data)
    } catch {
      throw new Error('Failed to fetch firmware (network)')
  }
}

// Return the browser_download_url for the latest Kiisu release .tgz suitable for given target (e.g., 'f7')
async function getKiisuUpdateTgzUrl(target?: string) {
  try {
    const repo = 'kiisu-io/kiisu-firmware'
    const gh = await fetchLatestReleaseJson(repo)
    const assets: GitHubAsset[] = gh?.assets || []
    const tag = gh?.tag_name || gh?.name || ''
    const matchTarget = (name: string) => {
      if (!target) return true
      // accept files containing exact target substring (e.g., f7)
      return name.toLowerCase().includes(target.toLowerCase())
    }
    const tgz = assets.find(
      (a): a is GitHubAsset & { name: string; browser_download_url: string } =>
        typeof a?.name === 'string' &&
        typeof a?.browser_download_url === 'string' &&
  /^kiisu_.*\.tgz$/i.test(a.name) &&
        matchTarget(a.name)
    )
    // Prefer mirror URL when tag and name are known
    if (tgz && tag) {
      return makeMirrorAssetUrl(repo, tag, tgz.name)
    }
  return undefined
  } catch {
    return undefined
  }
}

// Return the browser_download_url for the latest Kiisu release .dfu for given target (e.g., 'f7')
async function getKiisuDfuUrl(target?: string) {
  try {
    const repo = 'kiisu-io/kiisu-firmware'
    const gh = await fetchLatestReleaseJson(repo)
    const assets: GitHubAsset[] = gh?.assets || []
    const tag = gh?.tag_name || gh?.name || ''
    const matchTarget = (name: string) => {
      if (!target) return true
      return name.toLowerCase().includes(target.toLowerCase())
    }
    const dfu = assets.find(
      (a): a is GitHubAsset & { name: string; browser_download_url: string } =>
        typeof a?.name === 'string' &&
        typeof a?.browser_download_url === 'string' &&
  /^kiisu_.*\.dfu$/i.test(a.name) &&
        matchTarget(a.name)
    )
    if (dfu && tag) {
      return makeMirrorAssetUrl(repo, tag, dfu.name)
    }
  return undefined
  } catch {
    return undefined
  }
}

export const api = {
  fetchChannels,
  fetchRegions,
  fetchFirmware,
  fetchFirmwareTar,
  getKiisuUpdateTgzUrl,
  getKiisuDfuUrl
}
