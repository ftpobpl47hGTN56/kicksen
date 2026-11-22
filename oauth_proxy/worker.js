const JSON_HEADERS = { 'Content-Type': 'application/json; charset=utf-8' };

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    throw new Error('Invalid JSON');
  }
}

async function forwardTokenRequest(request, env) {
  const body = await readJson(request);
  const grantType = body.grant_type;
  if (!['authorization_code', 'refresh_token'].includes(grantType)) {
    return jsonResponse({ error: 'Unsupported grant type' }, 400);
  }
  if (grantType === 'authorization_code') {
    if (!body.code || !body.code_verifier) {
      return jsonResponse({ error: 'Missing code or PKCE verifier' }, 400);
    }
    if (body.redirect_uri !== env.KICK_REDIRECT_URI) {
      return jsonResponse({ error: 'Unexpected redirect URI' }, 400);
    }
  } else if (!body.refresh_token) {
    return jsonResponse({ error: 'Missing refresh token' }, 400);
  }

  const params = new URLSearchParams({
    client_id: env.KICK_CLIENT_ID,
    client_secret: env.KICK_CLIENT_SECRET,
    grant_type: grantType,
  });
  for (const field of ['code', 'code_verifier', 'redirect_uri', 'refresh_token']) {
    if (typeof body[field] === 'string') params.set(field, body[field]);
  }

  const response = await fetch('https://id.kick.com/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: params,
  });
  return new Response(response.body, {
    status: response.status,
    headers: JSON_HEADERS,
  });
}

async function forwardRevokeRequest(request, env) {
  const body = await readJson(request);
  if (!body.token) return jsonResponse({ error: 'Missing token' }, 400);

  const params = new URLSearchParams({
    client_id: env.KICK_CLIENT_ID,
    client_secret: env.KICK_CLIENT_SECRET,
    token: body.token,
  });
  const response = await fetch('https://id.kick.com/oauth/revoke', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: params,
  });
  return new Response(response.body, {
    status: response.status,
    headers: JSON_HEADERS,
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== 'POST') {
      return jsonResponse({ error: 'Method not allowed' }, 405);
    }

    try {
      if (url.pathname === '/token') return await forwardTokenRequest(request, env);
      if (url.pathname === '/revoke') return await forwardRevokeRequest(request, env);
      return jsonResponse({ error: 'Not found' }, 404);
    } catch (error) {
      return jsonResponse({ error: error.message || 'Invalid request' }, 400);
    }
  },
};
