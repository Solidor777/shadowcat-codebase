Part of the shadowcat-codebase-documents-permissions skill; read it when changing redaction, gm_role, Document.base egress, band classifiers or per-recipient broadcast transitions.

# Hard invariants: detailed bullets

The long Hard-invariant bullets in full: `filter_properties`, `gm_role`, `/base` egress, envelope-vs-content-band redaction and the whole-document READ transition.

| Part | Holds | Read it when |
|---|---|---|
| [hard-invariants-detail-01-filter-gm-role-base.md](hard-invariants-detail-01-filter-gm-role-base.md) | The `filter_properties` bullet; the `gm_role` bullet; the `/base` egress bullet | Changing `filter_properties`, `PermissionSet.gm_role` or `Document.base` egress |
| [hard-invariants-detail-02-redaction-and-read-transition.md](hard-invariants-detail-02-redaction-and-read-transition.md) | The content-band redaction bullet; the whole-document READ transition bullet | Changing redaction, `REDACTABLE_BANDS`, band classifiers or per-recipient broadcast filtering |
