#!/usr/bin/env python3
"""Render a PS 5.1 template from validated data; never interpolate executable input."""
import base64
import json
import re
import struct
import sys
from pathlib import Path


def render(source, config, openssh_sha, tailscale_sha):
    auth = config.get('tailscaleAuthKey', '')
    key = config.get('publicKey', '').strip()
    tailnet = config.get('expectedTailnet', '').lower().rstrip('.')
    endpoints = config.get('logEndpoints', [])
    if not isinstance(auth, str) or not re.fullmatch(r'tskey-auth-[A-Za-z0-9-]{20,}', auth):
        raise ValueError('invalid tailscaleAuthKey')
    parts = key.split()
    if len(parts) < 2 or parts[0] not in ('ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521') or '\n' in key or '\r' in key:
        raise ValueError('expected a single supported SSH public key')
    try:
        blob = base64.b64decode(parts[1], validate=True)
        size = struct.unpack('>I', blob[:4])[0]
        if blob[4:4 + size].decode('ascii') != parts[0] or len(blob) <= 4 + size:
            raise ValueError('public key wire type mismatch')
    except Exception as exc:
        raise ValueError('invalid public key encoding') from exc
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?', tailnet) or '.' not in tailnet or '..' in tailnet:
        raise ValueError('invalid expectedTailnet')
    from urllib.parse import urlsplit
    if not isinstance(endpoints, list) or len(endpoints) > 3:
        raise ValueError('logEndpoints must contain at most three HTTPS endpoints')
    for endpoint in endpoints:
        if not isinstance(endpoint, str) or any(ord(c) < 32 for c in endpoint):
            raise ValueError('invalid log endpoint')
        url = urlsplit(endpoint)
        if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment or url.query or not url.path.endswith('/events'):
            raise ValueError('log endpoints require HTTPS /events without credentials, query or fragment')
    for digest in (openssh_sha, tailscale_sha):
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('invalid pinned digest')
    def literal(value):
        return value.replace("'", "''")
    values = {
        '__TAILSCALE_AUTH_KEY__': literal(auth), '__SSH_PUBLIC_KEY__': literal(key),
        '__EXPECTED_TAILNET__': literal(tailnet), '__OPENSSH_SHA256__': openssh_sha,
        '__TAILSCALE_SHA256__': tailscale_sha,
        '__LOG_ENDPOINTS_JSON__': '@(' + ', '.join("'" + literal(e) + "'" for e in endpoints) + ')',
    }
    for marker in values:
        if source.count(marker) != 1:
            raise ValueError('template marker missing or duplicated: ' + marker)
    # A single pass prevents replacements from interpreting text inside input.
    return re.sub('|'.join(map(re.escape, values)), lambda m: values[m[0]], source)


if __name__ == '__main__':
    source, config, output, ssh_hash, ts_hash = sys.argv[1:]
    try:
        result = render(Path(source).read_text(encoding='utf-8-sig'), json.loads(Path(config).read_text()), ssh_hash, ts_hash)
        Path(output).write_text(result, encoding='utf-8-sig', newline='\r\n')
    except (ValueError, TypeError) as exc:
        sys.exit(str(exc))
