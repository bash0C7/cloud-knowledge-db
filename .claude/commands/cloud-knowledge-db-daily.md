---
description: Run cloud-knowledge-db daily ingestion (PLAN/CONFIRMED/EXECUTE). Dispatches the cloud-knowledge-db-daily subagent.
---

Dispatch the `cloud-knowledge-db-daily` subagent in PLAN mode. After receiving the PLAN report, await user confirmation. When the user replies with `CONFIRMED SINCE=YYYY-MM-DD BEFORE=YYYY-MM-DD`, re-dispatch the same subagent in EXECUTE mode passing that token.
