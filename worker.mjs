export function launcher(origin) {
  const archive = `${origin}/reinstall.tar.gz`.replaceAll("'", "'\\''");
  return `#!/usr/bin/env bash
set -e
dir=$(mktemp -d)
trap 'rm -rf -- "$dir"' EXIT
curl -fsS '${archive}' -o "$dir/source.tar.gz" || wget -qO "$dir/source.tar.gz" '${archive}'
tar -xzf "$dir/source.tar.gz" -C "$dir"
test -s "$dir/reinstall-Po0/reinstall.sh"
rm -f "$dir/source.tar.gz"
trap - EXIT
exec bash "$dir/reinstall-Po0/reinstall.sh" "$@"
`;
}

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/reinstall.sh") {
      if (!["GET", "HEAD"].includes(request.method)) {
        return new Response("Method not allowed", { status: 405 });
      }
      url.protocol = "https:";
      url.port = "8443";
      return new Response(request.method === "HEAD" ? null : launcher(url.origin), {
        headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
      });
    }
    return env.ASSETS.fetch(request);
  },
};
