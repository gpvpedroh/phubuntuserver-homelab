# Case Study: A Container Couldn't Join Its Own Network — Because the Network's Name Wasn't What It Looked Like

**Date:** 2026-07-28 (surfaced during the PhotoPrism → Immich migration)
**Tags:** docker / docker-compose / networking

## The problem

A one-off `docker run` command, needed to join an external CLI tool to
the stack's internal `homelab` bridge network for the Immich bulk-import
job, failed to find that network at all — despite `docker-compose.yml`
defining a network literally named `homelab`:

```yaml
networks:
  homelab:
    driver: bridge
```

```bash
docker run --network homelab ...
# Error: network homelab not found
```

## The investigation

The network name in the compose file was correct, and `docker compose
up` had brought the stack up without any errors — every service defined
in the file could reach every other service by name over that network,
as expected. So the network clearly existed and was working. The
question was why an *external*, non-Compose-managed container couldn't
see it under the name written in the YAML.

Checking the actual registered network name directly, rather than
assuming the YAML name was the runtime name, resolved it immediately:

```bash
docker network ls
```

## The root cause

Docker Compose automatically prefixes network names with the project
directory name at creation time. A network declared as `homelab` in
`docker-compose.yml` doesn't get created as `homelab` — it gets created
as `<project_directory_name>_homelab` (in this case, something like
`docker_homelab`, matching the directory the compose file lived in).
Every Compose-managed service resolves the network correctly because
Compose itself tracks the mapping internally; a manually-run `docker run`
command has no such awareness and needs the literal registered name.

## The fix

Rewrote the one-off command to target the actual registered network name
returned by `docker network ls`, rather than the name as written in the
compose file.

## Lesson

Always verify a resolved resource's real name against actual tooling
output rather than assuming the name you wrote in a config file is the
name that got registered at runtime — this applies broadly whenever a
higher-level tool (Compose, Kubernetes, a package manager) applies its
own naming convention on top of a name you supplied.
