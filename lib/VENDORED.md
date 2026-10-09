# Vendored dependencies

`lib/` holds plain, tracked files — **not** git submodules. A clone of this repository is
complete: there is no `git submodule update` step, and no nested `.git` directory exists
anywhere under this tree. `forge install` / `forge update` will not work here; to move a
dependency, replace its directory by hand and update the commit recorded below.

| Path             | Upstream                              | Commit                                     | Version  |
| ---------------- | ------------------------------------- | ------------------------------------------ | -------- |
| `lib/forge-std`  | https://github.com/foundry-rs/forge-std | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` | `v1.16.2` |

## What was kept

`lib/forge-std` is the upstream tree verbatim, less its `.git` and `.github` directories.

