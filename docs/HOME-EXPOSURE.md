# Home directory exposure check

`scripts/check-home-exposure.sh` answers one question: **can another local
account read credential-shaped files in this home directory?**

It matters most on hosts where AI agents, CI runners or services run under
their own accounts next to a human owner. Separate accounts are a good
boundary only while the owner's home directory actually stays closed.

## The failure it catches

A home directory created with mode `0750` or `0700` looks private, so files
inside it are often left world-readable: `.env` files written by tools with
the default umask, SQLite databases, backup copies of configuration.

That is safe until something grants another principal the execute
(traverse) bit on the home directory itself. Common ways this happens:

- an ACL entry such as `setfacl -m u:agent-runner:--x ~` added so that a
  separate agent account can reach one binary or one work directory;
- the owning group gains members besides the owner;
- the mode is widened to `0751` or `0755`.

After that, the grant reaches far beyond the intended path. The extra
account can open any world-readable file below world-traversable
directories, which on a typical developer machine includes most project
trees.

## What it reports

```console
$ bash scripts/check-home-exposure.sh

== DIRECTORY ==
path:   /home/developer
mode:   750
owner:  developer
group:  developer

== WHO ELSE CAN TRAVERSE IT ==
other:        no execute bit
group:        'developer' has execute; no listed members besides the owner
              (accounts whose PRIMARY group is 'developer' are not listed by getent)
acl:          user agent-runner (1201) can traverse (entry --x, mask r-x)

== CREDENTIAL-SHAPED FILES REACHABLE THROUGH WORLD-READABLE PATHS ==
(walk-rule notes omitted)

  664  /home/developer/projects/example-api/.env
  644  /home/developer/projects/example-api/data/app.db

VERDICT: EXPOSED — 2 credential-shaped file(s) readable by:
  - ACL user agent-runner (1201)
```

Only paths and octal modes are printed. File contents are never opened.

| Verdict | Meaning | Exit |
|---|---|---|
| `PRIVATE` | no principal besides the owner can traverse the directory | 0 |
| `TRAVERSABLE` | someone else can traverse, but no credential-shaped file is reachable | 0 |
| `EXPOSED` | at least one credential-shaped file is reachable | 1 |
| `UNKNOWN` | the directory or its ACL could not be evaluated (for example, an ACL exists but `getfacl` is not installed) | 2 |

Options: `--home DIR` checks another directory you can read; `--max N`
limits the listing (default 50).

## Limits

- The walk follows the **other** permission bits. A group or ACL principal
  may reach more than that, so for them the listing is a lower bound.
  Directories deeper in the tree that carry their own ACLs are not modelled.
- Files are matched by name (`.env*`, `*.env`, private-key names, `*.pem`,
  `*.key`, `.netrc`, `.pgpass`, `.git-credentials`, `*.db`, `*.sqlite*`,
  and similar). Templates such as `*.example` and public keys are skipped.
  A secret in an unusually named file is not found.
- Large tool directories (`.git`, `node_modules`, `.cache`, virtualenvs)
  are skipped for speed.
- Inside a user namespace (a container or an agent sandbox), ACL entries
  for ids outside the namespace's map are shown as `4294967295`. The script
  still reports them as principals that can traverse, labelled as such.
  A mask with no named entries is what `setfacl -x` leaves behind and
  grants nothing.
- Accounts whose primary group is the home directory's group are not listed
  by `getent group`; the script says so instead of claiming none exist.

## Remediation (yours to decide)

The script changes nothing. Typical fixes, after confirming no other account
legitimately reads the files:

- `chmod o-rwx` on the reported files, or on the directory that holds them;
- give the extra account its own directory outside the home, instead of a
  traverse grant on the home itself;
- remove an ACL entry that is no longer needed: `setfacl -x u:NAME ~`.

Re-run the check afterwards. An `EXPOSED` verdict should become `TRAVERSABLE`
or `PRIVATE`.
