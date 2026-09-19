#!/usr/bin/env bash
# Asks the provider questions of a candidate stack and prints one line each.
#
# Usage: probe-stack.sh
#
# Environment, all optional. A question with nothing to work from prints
# NOT MEASURED and the measurement to go and take by hand.
#
#   PGURL         a libpq connection string to the Chatwoot database, as the
#                 privileged role, from inside the network that reaches it
#   S3_ENDPOINT   object store endpoint, e.g. https://s3.example.com
#   S3_BUCKET     bucket name, with credentials in the usual AWS variables.
#                 A region is set for you if you have none: the CLI insists on
#                 one even where the store ignores it.
#   BASE_URL      the public address, once the installation answers on it
#
# Run it before you commit to a stack, and again after changing any part of it.
# See providers.md for what each answer decides.
set -uo pipefail

ok()   { printf '  %-14s %s\n' 'MEASURED' "$1"; }
bad()  { printf '  %-14s %s\n' 'PROBLEM'  "$1"; }
skip() { printf '  %-14s %s\n' 'NOT MEASURED' "$1"; }
q()    { printf '\n%s\n' "$1"; }

# --- 1. Postgres ------------------------------------------------------------
q '1. Does Postgres meet the version floor and carry the five extensions?'
if [[ -n "${PGURL:-}" ]] && command -v psql >/dev/null; then
  VER="$(psql "$PGURL" -tAc 'SHOW server_version' 2>/dev/null)"
  if [[ -z "$VER" ]]; then
    bad "cannot connect with PGURL. Check the host, the port and the network."
  else
    ok "server_version $VER (Chatwoot needs 14 or later)"
    for ext in pg_stat_statements pg_trgm pgcrypto plpgsql vector; do
      AVAIL="$(psql "$PGURL" -tAc "SELECT 1 FROM pg_available_extensions WHERE name='$ext'" 2>/dev/null)"
      INST="$(psql "$PGURL" -tAc "SELECT 1 FROM pg_extension WHERE extname='$ext'" 2>/dev/null)"
      if [[ "$INST" == 1 ]]; then ok "$ext installed"
      elif [[ "$AVAIL" == 1 ]]; then ok "$ext available, not yet created"
      else bad "$ext is NOT available on this server. Chatwoot's schema needs it."
      fi
    done
  fi
else
  skip 'set PGURL and install psql. By hand: connect and run'
  printf '                 %s\n' "SHOW server_version; SELECT name FROM pg_available_extensions" \
                                 "WHERE name IN ('pg_stat_statements','pg_trgm','pgcrypto','plpgsql','vector');"
fi

q '2. What port does Postgres listen on, and did you write that port down?'
if [[ -n "${PGURL:-}" ]]; then
  PORT="$(sed -nE 's/.*[ =]port=([0-9]+).*/\1/p' <<<"$PGURL")"
  [[ -n "$PORT" ]] && ok "PGURL names port $PORT" ||
    skip 'PGURL does not name a port, so libpq will use 5432.'
  echo '                 A managed provider often listens somewhere else. The'
  echo '                 container entrypoint probes the port you configure and'
  echo '                 waits for ever on the wrong one, with no useful error.'
else
  skip 'By hand: read the port off your provider connection details.'
fi

q '3. Can the admin role create extensions and hand over ownership?'
if [[ -n "${PGURL:-}" ]] && command -v psql >/dev/null; then
  WHO="$(psql "$PGURL" -tAc 'SELECT current_user' 2>/dev/null)"
  SUPER="$(psql "$PGURL" -tAc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user" 2>/dev/null)"
  [[ -n "$WHO" ]] && ok "connected as $WHO, superuser=$SUPER"
  echo '                 Not superuser is normal on a managed cluster. What'
  echo '                 matters is whether db-init.sql runs without error:'
  echo '                 it falls back to explicit grants when ownership is refused.'
else
  skip 'By hand: run templates/db-init.sql and read what it prints.'
fi

q '4. What is the statement timeout, and will it survive a migration?'
if [[ -n "${PGURL:-}" ]] && command -v psql >/dev/null; then
  ST="$(psql "$PGURL" -tAc 'SHOW statement_timeout' 2>/dev/null)"
  if [[ -z "$ST" || "$ST" == "0" ]]; then
    ok "statement_timeout is ${ST:-unknown}, so nothing cuts a long migration"
  else
    bad "statement_timeout is $ST. Pass POSTGRES_STATEMENT_TIMEOUT=600s to the"
    echo '                 prepare command, and only to that command.'
  fi
else
  skip 'By hand: SHOW statement_timeout;'
fi

# --- 5. Object storage ------------------------------------------------------
q '5. Does the object store accept a write, a read and a delete?'
if [[ -n "${S3_ENDPOINT:-}" && -n "${S3_BUCKET:-}" ]] && command -v aws >/dev/null; then
  # The CLI refuses to run without a region even against a store that ignores
  # it. Without this, every call below fails before it reaches the endpoint and
  # the failure reads like bad credentials.
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
  KEY="chatwoot-probe-$$"
  TMP="$(mktemp)"; echo probe >"$TMP"
  if aws s3api put-object --bucket "$S3_BUCKET" --key "$KEY" --body "$TMP" \
       --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1; then
    ok 'put-object succeeded'
    aws s3api get-object --bucket "$S3_BUCKET" --key "$KEY" /dev/null \
      --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1 && ok 'get-object succeeded' || bad 'get-object failed'
    aws s3api delete-object --bucket "$S3_BUCKET" --key "$KEY" \
      --endpoint-url "$S3_ENDPOINT" >/dev/null 2>&1 && ok 'delete-object succeeded' || bad 'delete-object failed'
  else
    bad 'put-object failed. Check the credentials, the bucket and the endpoint.'
  fi
  rm -f "$TMP"
  echo '                 A passing probe is necessary, not sufficient: some'
  echo '                 stores accept the CLI and still reject what Chatwoot'
  echo '                 sends. Upload a real attachment before you commit.'
else
  skip 'set S3_ENDPOINT, S3_BUCKET and AWS credentials, and install the aws CLI.'
  echo '                 By hand: attach a file to a conversation and confirm the'
  echo '                 object appears in the bucket and downloads again.'
fi

# --- 6. Mail ----------------------------------------------------------------
q '6. Does mail leave, and can anything arrive back?'
skip 'No probe. Sending needs a verified domain and a real delivery, and'
echo '                 whether replies parse is a property of the provider.'
echo '                 By hand: trigger a password reset, confirm it arrives and'
echo '                 that SPF, DKIM and DMARC all pass at the receiver. Then'
echo '                 check whether your provider can receive at all: several'
echo '                 send only, and Chatwoot has no adapter for some of those.'

# --- 7. The edge ------------------------------------------------------------
q '7. Which client address reaches Rails, and can a client forge it?'
if [[ -n "${BASE_URL:-}" ]] && command -v curl >/dev/null; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H 'X-Forwarded-For: 203.0.113.1' -H 'CF-Connecting-IP: 203.0.113.1' "${BASE_URL%/}/api")"
  ok "the public address answered $CODE to a request carrying forged address headers"
  echo '                 That only proves it answered. Read the origin log for'
  echo '                 that request and see which address Rails recorded. If it'
  echo '                 is 203.0.113.1, a client picks its own rate-limit bucket.'
else
  skip 'set BASE_URL. By hand: send a request with a forged address header and'
  echo '                 read which address the origin logged.'
fi

q '8. Does the address survive a rebuild of the host?'
skip 'No probe. By hand: check whether your provider gives you an address that'
echo '                 detaches from one machine and attaches to the next. If it'
echo '                 does not, every rebuild is also a DNS change and a wait.'

printf '\nRead providers.md for what each answer decides.\n'
