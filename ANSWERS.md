# Project 1 — Answers

## Part A — Understand the build

Environment: WSL2 Ubuntu, Node v24.12.0 (the README asks for Node 22 LTS), pnpm 10.23.0 (via `corepack enable`).

```bash
corepack enable --install-directory ~/.local/bin
pnpm install --frozen-lockfile
pnpm check && pnpm test && pnpm build
```

### 1. Files in `dist/` and why the names contain hashes

```text
$ find dist -type f -exec ls -l {} \;
dist/index.html                    791 B
dist/manus-routes.json              60 B
dist/africair-mark.svg             352 B
dist/assets/index-CBj_wgb2.css   44,666 B
dist/assets/index-D8WT6gtn.js   117,585 B   app code
dist/assets/index.es-C05bQb9q.js 159,767 B  (jsPDF dependency chunk)
dist/assets/react-CpYK3H_K.js   223,309 B   React
dist/assets/airports-BrwcO3ZA.js 289,186 B  airport dataset
dist/assets/pdf-o1MWN_TF.js     584,775 B   jsPDF / html2canvas / dompurify
```

The hash is a fingerprint of the file's **content**, added by Vite at build time. If the content changes, the name
changes. The name `index-D8WT6gtn.js` therefore always refers to exactly one set of bytes. That allows every file under
`assets/` to be served with `Cache-Control: public, max-age=31536000, immutable`: browsers and CDNs can keep it for a
year and never need to revalidate. A new release produces new names, and the (never cached) `index.html` points to them.

Without hashes (`app.js` always) there are two bad choices. Either cache it for a long time, and users keep running the
**old** JavaScript after a deploy, possibly against a new `index.html`, which breaks the app. Or don't cache it, and
every visit re-downloads about 1.4 MB. Hashes also stop a half-finished deploy from mixing old and new files, because
old and new assets live side by side under different names.

### 2. `tsc -b` vs `vite build`

- `tsc -b` runs the TypeScript compiler in build mode over the project references (`tsconfig.app.json`,
  `tsconfig.node.json`). It **type-checks**. It writes no files to `dist/`, only an incremental `.tsbuildinfo` cache. It
  is a quality gate: a type error fails the build.
- `vite build` bundles, minifies and tree-shakes the code, splits it into chunks, hashes the file names, rewrites
  `index.html`, copies `public/`, and **writes `dist/`**. It strips types but does not check them.

So only `vite build` produces `dist/`. The `&&` in `"build": "tsc -b && vite build"` means type errors stop the build
before bundling starts.

### 3. Why `--frozen-lockfile`? (experiment)

`--frozen-lockfile` makes pnpm install exactly what `pnpm-lock.yaml` records, with the recorded integrity hashes. If
`package.json` and the lockfile disagree, it **fails** instead of resolving new versions.

Experiment (in a scratch copy, not in the repo): delete `pnpm-lock.yaml`, then run `pnpm install`.

```text
$ rm pnpm-lock.yaml && pnpm install        # a new lockfile was generated; the diff against the original shows:
react                 19.3.0  ->  19.3.1
react-dom             19.3.0  ->  19.3.1
@playwright/test      1.64.0  ->  1.64.1
playwright(-core)     1.64.0  ->  1.64.1
postcss               8.5.30  ->  8.5.31
core-js               3.50.0  ->  3.51.0
browserslist 4.29.3 -> 4.29.4, caniuse-lite, electron-to-chromium, node-releases, rollup natives ... (all re-resolved)
```

`package.json` only says `^19.3.0`, `^1.64.0` and so on, so pnpm picked the newest versions that satisfy those ranges.
Nobody changed the code, and the dependencies still changed.

Why that is dangerous in CI:
- **Not reproducible:** the same commit builds different software on Monday and on Friday. "It worked yesterday" can't
  be debugged.
- **Silent upgrades:** a broken or compromised release of any transitive dependency enters production with no code review
  (a supply-chain risk). The lockfile's integrity hashes are what protect against a tampered package.
- **Tool mismatch:** the Docker image used for the Playwright tests (Project 2) is pinned to `v1.64.0`. A drifted
  1.64.1 library would no longer match the browsers in that image.
- **Dev and CI differ:** the artifact tested is not the artifact developers ran.

### 4. `manualChunks` and `chunkSizeWarningLimit`

- `manualChunks` tells Rollup how to group modules into output files, instead of its automatic choice. Here the PDF
  libraries (`jspdf`, `html2canvas`, `dompurify`) go to a `pdf` chunk, the airport dataset (`airports.json`) to `airports`
  and React to `react`. Rarely-changing vendor code then keeps a stable hash across releases, so returning visitors keep
  it in cache and only re-download the small app chunk.
- `chunkSizeWarningLimit: 700` raises the size (in kB) above which Vite prints "chunk is larger than ..." from the
  default 500 to 700. It only silences a warning. It doesn't change the output. The comment in the config says it is
  there because jsPDF alone is about 585 kB.

Largest chunk: `pdf-o1MWN_TF.js`, 584,775 B (about 571 KiB), 175 kB gzipped. It matters on 3G (roughly 0.4 to 1.6 Mbit/s
in practice). 175 kB gzipped is about 1 to 3.5 seconds of pure transfer, before any parse time. This chunk is only
needed for the PDF confirmation, yet the built `dist/index.html` has `<link rel="modulepreload" href="/assets/pdf-...js">`,
so every first visit downloads it even if the user never books. A separate chunk is a good first step, but it only helps
if the chunk is loaded on demand (a dynamic `import()` when the user clicks download). Splitting makes caching better,
and lazy loading would make the first load faster. (`airports` at 108 kB gzipped is the next biggest and is needed
for the search form.)

### 5. Why `pnpm dev` must never serve production traffic

1. **Unoptimised output:** the dev server serves unbundled, unminified ES modules, one request per module (about 1,800
   here), with no hashed names or cache headers. The site is much slower than the 1.4 MB `dist/`.
2. **Not hardened or supported:** it is a development tool with hot-module-reload websockets and verbose error overlays
   that leak source paths and code. It has no tuned timeouts, no real access logs or health endpoint, and no TLS, and
   the Vite team does not support it for production. Vite also has had file-read vulnerabilities in dev-server mode.
3. **Fragile process:** one Node process with no supervision. If it crashes there is no restart. It runs as whichever
   user started it, and it can't be zero-downtime deployed. Here it also binds `0.0.0.0` with `strictPort`, so a busy
   port makes it exit.

(Also: it needs the whole source tree, the dev dependencies and `node_modules` on the server. A static server only
needs `dist/`.)

### 6. Size of `dist/`

```text
$ du -sh dist
1.4M    dist
$ tar czf - dist | wc -c
451174
```

`dist/` is about 1.4 MB on disk (1,461,000 bytes of files) and **451,174 bytes (about 441 KiB) as a gzipped tar**.

---

### Note: `pnpm test` fails on this machine

`pnpm check` and `pnpm build` pass. `pnpm test` reports **1 failed, 29 passed, 3 skipped** (the 3 skipped need
`TEST_DATABASE_URL`).

```text
FAIL server/src/app.test.ts > configuration > prefers NAME_FILE and picks up a rotated file after the refresh interval
AssertionError: expected 'first-token' to be 'rotated-token'
```

Cause: the test writes a file, then rewrites it a few milliseconds later. The reader (`server/src/config.ts`) skips
re-reading when the file's `mtime` is unchanged. On this kernel two writes made within one clock tick get the same mtime:

```text
$ node -e "...writeFileSync('x','a'); stat; writeFileSync('x','bb'); stat..."   # -> same mtimeMs, true
```

So the test is timing dependent, and it fails here every time. Real secret rotation, seconds or more apart, is not affected.
This matters for `build.sh`, which must stop on test failure (exit code 30).

---

# Part B — Ship it to a Linux server (EC2)

## B1. Server

Region `us-east-2`. Ubuntu Server 24.04 LTS (Canonical AMI), `t3.small`, 20 GiB gp3 (delete on termination), public subnet.
Security group `africair-web-sg`: 22 from my IP only, 80 and 443 from anywhere. IAM role `africair-ec2-ssm`
(`AmazonSSMManagedInstanceCore`) attached as an instance profile. Tags `Project=africair`, `Owner=ES` on the instance and volume.
IMDSv2 is required (the console default).

Why a role and not an IAM user: a role gives the instance short-lived credentials that AWS rotates, so there is no access key to
store, leak or rotate by hand.

Mistake and fix: I first launched a `t2.micro` (1 GiB RAM). I stopped the instance, changed the type to `t3.small` under
Actions > Instance settings, and started it again. The public IP changed after the restart because it is not an Elastic IP.

## B2. `bootstrap.sh`

`scripts/ops/bootstrap.sh`. Each step checks the current state first and acts only if something is missing, so a re-run changes
nothing. The firewall rules are added before `ufw enable`, so an SSH session is never cut off.

Two consecutive runs on the server (the second and third run; the first-run output was not captured):

    [bootstrap] apt packages already installed
    [bootstrap] Node.js 22 already installed
    [bootstrap] corepack enabled
    [bootstrap] user africair already exists
    [bootstrap] ufw already active
    [bootstrap] done. changes made this run: 0
    exit code: 0

`ufw status` shows only 22 (OpenSSH), 80 and 443 allowed, IPv4 and IPv6. nginx is `active`.

Finding from testing in a Docker container first: `ufw allow OpenSSH` failed because the profile comes from `openssh-server`,
so I added that package to the list. `ufw` itself cannot run in a plain container (no permission for iptables), so the firewall
step was only proven on the EC2 instance.

## B3. `build.sh`

`./build.sh main` on the server exited 0 and produced `africair-7f01253.tar.gz` and a `.sha256` file. `sha256sum -c` prints OK.
`version.json` (written with `jq -n --arg`) contains commit, ref, builtAt, builtBy and nodeVersion (`v22.23.4`).

Exit codes: 10 checkout, 20 install, 30 check/test, 40 build, 50 packaging (my addition), 1 usage. They are listed in `--help`.
`pnpm check` and `pnpm test` both use 30 because the brief does not give the type check its own code.

The asset hashes on the server (`index-D8WT6gtn.js`, `pdf-o1MWN_TF.js`, ...) are identical to my local build, so the build is
deterministic across machines. The tarball is made with sorted entries, no owner data and `gzip -n`, but `builtAt` in
`version.json` changes on every build, so two builds of one commit still differ in their checksum.

`pnpm test` fails on my WSL machine (a timing test, see the note above) and passed on the server. The `exit 30` path itself was
not exercised.

## B4. `deploy.sh` and `rollback.sh`

Atomic switch. `ln -sfn target current` on an existing link first removes the old link and then creates the new one, as two
steps. In between, `current` does not exist and a request can get a 404. Instead I create the link under a temporary name and
run `mv -T tmp current`. A rename is a single atomic system call, so a visitor always sees the old or the new release.

Health check: `/healthz` must return `ok`, `/version.json` must carry the commit that was deployed, and `/` must return 200.

Results:
- First deploy: `healthy`, exit 0.
- `rollback.sh`: `rolled back: ...030747Z -> ...022131Z`, exit 0, `/` still 200.
- Automatic rollback (a release with `index.html` removed):

      africair-bad0001.tar.gz: OK
      ==> switching current -> 20261025T031450Z-bad0001
      FAILED: health check did not pass. Rolling back.
      Rolled back to /opt/africair/releases/20261025T022131Z-7f01253
      exit code: 1

Bugs found while testing:
1. On a first deploy, `readlink -f current` returns the path itself when the link is missing, so a failed first deploy "rolled
   back" to `/opt/africair/current` and made `current` point at itself. Fixed: `PREVIOUS` is set only if `current` is a symlink,
   and a rollback target must be inside `releases/`.
2. The first deploy failed its health check because I had not installed the nginx site yet (the stock default site answered).
3. `/` returned 404 after the first config. I changed `try_files $uri =404` to `try_files $uri $uri/ =404`. The 404 I still saw
   right after the reload went away by the next request, so I believe it was a timing effect, but I did not prove it.
4. The health check originally ignored `/`, so a broken home page would have passed. It now requests `/` too.

The failed releases stay on disk until pruned (5 are kept). A failed release folder is not deleted automatically.

## B5. nginx

`deploy/nginx/africair.conf`, `deploy/nginx/africair-security-headers.conf`, `deploy/logrotate/africair`.
Security headers live in one snippet that every `location` includes, because a `location` with its own `add_header` (needed for
`Cache-Control`) discards the headers it would inherit. `/healthz` is not logged. `/assets/` is `immutable` for a year.
`index.html` and `version.json` are `no-cache`. Unknown paths return a real 404. The access log is JSON.

Not verified: the Content-Security-Policy against a real browser session (console messages, PDF download), the headers on each
location, and the logrotate rule.

## B6. Health monitoring

`healthcheck.sh` plus `africair-healthcheck.service` and `.timer` (every minute). The failure count is kept in
`/var/lib/africair/healthcheck.failures` (`StateDirectory=africair`). After 3 failures it logs a WARNING, runs
`systemctl reload-or-restart nginx` (so it also starts a stopped nginx) and resets the counter.

I stopped nginx on purpose:

    03:21:25 OK
    03:22:26 FAILED (1 consecutive)
    03:23:27 FAILED (2 consecutive)
    03:24:28 FAILED (3 consecutive)
    03:24:28 WARNING: 3 consecutive failures, reloading nginx
    03:25:29 OK

## B7. `report.sh`

Uses only `jq`, `awk`, `sort` and `uniq`. After 47 test requests in one minute, the per-minute table showed `47 2026-10-25T03:29`,
which matches 30 + 10 + 5 probes + 2 others. Only parts of the report were checked.
