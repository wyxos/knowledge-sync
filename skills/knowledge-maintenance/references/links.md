# Knowledge links

Resolve the base URL from installed service.json and the connected service's root, then follow the service's renderer/link conventions. Use absolute descriptive Markdown links for navigable Knowledge documents: <base-url>/content/<relative-path>. The root is <base-url>/content.

Use the rendered heading ID for section links. Confirm IDs when punctuation, Unicode or repeated headings make the slug uncertain. Renamed headings and shifted source lines can invalidate older fragments.

Return the tool-provided highlight_url for edits/restores. When authoring manual changed-text links supported by the service, use one-based source-line selectors such as #L12, #L12-L16 or #L12-L16,L28-L30; exact visible text can use #L12~percent-encoded-text and !2 for a later occurrence. These refer to the current document, so inspect an older link before reusing it.

Link only active, verified destinations. Keep credential-bearing URLs and secret query values out of links. Show remote filesystem paths in the target host's native syntax and identify the host; use a local opener only when it is verified to act on that host. Harness-specific artifact links follow the harness's supported format. Never enable unsafe renderer links to make a path navigable.
