# Concepts

These pages explain how Con Services is put together and why. Read them when
you want to understand what happens behind the screens, before you run Con
Services for real, or before you build against its APIs or write a module
of your own.

A good reading order for newcomers:

1. [Design principles](design-principles.md): the ten rules the suite is
   built on (one login, Den first, isolated modules, APIs instead of shared
   databases, secret managers, pinned versions) and what each means for
   you.
2. [Architecture](architecture.md): the pieces of the suite and their
   Kubernetes namespaces, how a request travels from the browser to a
   module, and how modules call each other.
3. [Authentication](authentication.md): how signing in works, how backends
   check who is calling, how Keycloak groups become roles, and how machines
   authenticate.
4. [Pairing](pairing.md): how a module connects to Den, what it receives,
   and what happens when Den is not there.
5. [API conventions](api-conventions.md): the rules every module's API
   shares: URL prefixes, tokens, the error format, health endpoints,
   versioning, and how to get a token for `curl`. Every module's API
   reference builds on this page.

Keep the [Glossary](glossary.md) open in another tab: it defines every term
used across these docs.

Design that is decided but not built yet lives under
[Proposals](../proposals/index.md). The first one is
[Staff communications](../proposals/staff-communications.md) (Herald notices
and meeting cards; chat and calls stay external).
