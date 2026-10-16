# Record maintenance

## Establish the destination

Search with the task's terms; refine weak matches and read the selected current document. Follow the service's existing organization and naming rules. Prefer the authoritative existing section over a new document. Separate product behavior, engineering/runtime guidance and settled decisions where that improves retrieval; keep small subjects together until a split is useful.

Source behavior alone does not repeal a stated product boundary. Distinguish current decisions, rejected behavior, deferred scope and undecided proposals. Preserve rationale and evidence only where they affect present operation. A proposed change or exploratory question alone is not an ongoing decision.

Read every destination before changing it. Consolidation includes locating callers, moving each fact once, updating relevant pointers and preserving facts that still matter. Avoid empty companion files, speculative directories or new indexes where the service already provides routing.

## Check procedure ownership before writing

Before adding or expanding a procedure in Knowledge, inspect the available skill catalog and the service's skill/source record. Read the relevant candidate entrypoints and supporting references; a skill name or description alone does not establish whether it already covers the workflow.

If a skill owns the procedure, reuse it. When the authorized task requires a missing or corrected step, update its maintained source through the applicable skill-maintenance workflow, verify it, then save a short pointer in Knowledge. Keep current project facts, decisions, permission boundaries and necessary local constraints beside that pointer. Inspect maintained scripts/contracts for executable mechanics rather than copying their recipe.

Create a new skill only when there is no suitable owner, the procedure has a distinct reusable scope and the task authorizes skill creation. If the candidate skill or source cannot be inspected, report the ownership gap and keep the proposed procedure in task artifacts until resolved; do not silently save another durable copy.

## Write concise records

When the record defines agent behavior, apply [Agent guidance](agent-guidance.md); factual records do not need that authoring workflow.

Keep current facts, settled decisions and the context needed to act. Use Product for purpose and capabilities, Engineering for implementation and operations, and Decisions for settled choices when that matches the service's organization. Keep small subjects together.

Give each fact or rule one authoritative home. Knowledge holds service/project facts, decisions and permission boundaries; reusable writing and operating procedures belong in their owning skills. Keep executable mechanics with maintained scripts or contracts. When moving a procedure, verify the receiving skill and replace the copied instructions with a useful pointer; preserve local constraints beside it.

Write directly, without repeated attribution or personal names unless identity, legal status or authorship matters. Preserve necessary account labels, addresses and other exact identifiers. Consolidate repeated explanations and retain rationale only where it affects current decisions.

During updates, remove superseded incident narratives, completed migration logs, test counts and obsolete warnings from active prose when recoverable history preserves them. Temporary progress and tentative discussion stay in task artifacts. Preserve current evidence, uncertainty, permission boundaries and environment-specific constraints; brevity is not a reason to discard them. Explicit user direction can revise an earlier decision.

## Write and verify

1. Confirm the change is verified, established or explicitly settled and belongs in durable Knowledge.
2. Read the current record and retain its returned checksum.
3. Use edit_knowledge for a small exact replacement. Use update_knowledge for a genuine complete rewrite, preserving unrelated content. Create only when no suitable authoritative home exists.
4. Pass the latest expected_checksum. If rejected as stale, reread and reconcile the user's intended change against the new version. Do not overwrite the newer record.
5. After an uncertain write, read the destination before retrying. Read successful writes back and verify the intended content, preserved context, links and callers.
6. Report the affected documents with returned highlight_url links and useful limitations. A search index can lag the committed document; verify through direct reads rather than repeatedly searching for completion.

## History and archive

Use knowledge_history and read_knowledge with revision to inspect old content before restoring it. Read the current version for its checksum, then restore only the intended revision and verify the resulting current record. A restore creates a new version rather than erasing history.

Archive superseded documents when recoverable history remains useful. Check active callers and update them to the current replacement. Avoid linking archived content as current guidance. Permanent deletion requires explicit user approval and is never a substitute for routine consolidation; the root document is protected.

Keep the report limited to actual created, updated, consolidated, restored or archived records and their effect.
