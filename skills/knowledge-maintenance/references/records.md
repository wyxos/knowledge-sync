# Record maintenance

## Establish the destination

Search with the task's terms; refine weak matches and read the selected current document. Follow the service's existing organization and naming rules. Prefer the authoritative existing section over a new document. Separate product behavior, engineering/runtime guidance and settled decisions where that improves retrieval; keep small subjects together until a split is useful.

Source behavior alone does not repeal a stated product boundary. Distinguish current decisions, rejected behavior, deferred scope and undecided proposals. Preserve rationale and evidence only where they affect present operation. A proposed change or exploratory question alone is not an ongoing decision.

Read every destination before changing it. Consolidation includes locating callers, moving each fact once, updating relevant pointers and preserving facts that still matter. Avoid empty companion files, speculative directories or new indexes where the service already provides routing.

## Write and verify

1. Confirm the change is verified, established or explicitly settled and belongs in durable Knowledge.
2. Read the current record and retain its returned checksum.
3. Use edit_knowledge for a small exact replacement. Use update_knowledge for a genuine complete rewrite, preserving unrelated content. Create only when no suitable authoritative home exists.
4. Pass the latest expected_checksum. If rejected as stale, reread and reconcile the user's intended change against the new version. Do not overwrite the newer record.
5. After an uncertain write, read the destination before retrying. Read successful writes back and verify the intended content, preserved context, links and callers.
6. Report the affected documents with returned highlight_url links and useful limitations. A search index can lag the committed document; verify through direct reads rather than repeatedly searching for completion.

Active records describe supported present facts and procedures. Keep temporary progress, assumptions, completed migration logs and obsolete warnings in task history or recoverable archives according to root guidance. A deployment/runbook record should preserve its actual environment-specific constraints.

## History and archive

Use knowledge_history and read_knowledge with revision to inspect old content before restoring it. Read the current version for its checksum, then restore only the intended revision and verify the resulting current record. A restore creates a new version rather than erasing history.

Archive superseded documents when recoverable history remains useful. Check active callers and update them to the current replacement. Avoid linking archived content as current guidance. Permanent deletion requires explicit user approval and is never a substitute for routine consolidation; the root document is protected.

Keep the report limited to actual created, updated, consolidated, restored or archived records and their effect.
