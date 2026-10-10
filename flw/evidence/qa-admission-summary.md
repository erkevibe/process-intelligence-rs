# Independent full admission observation

qa_process uploaded generated synthetic inputs through live multipart HTTP. Eleven checks passed: byte limit20MiB accepted/20MiB+1 rejected413; events100000 accepted/100001 rejected422; cases20000 accepted/20001 rejected422; ASCII activity4096 bytes accepted/4097 rejected422; Unicode activity4096 bytes accepted/4097 rejected422; benchmark1000cases/10000events/20activities exact counts. Every rejected input retained complete previous export.

Benchmark debug live server: HTTP upload wall391.402ms; server-reported parse+analysis378ms. Process lifetime PeakWorkingSet64=115347456bytes (~110MiB), measured after benchmark; this includes earlier boundary uploads and is not precise per-job RSS. Release5s target remains unverified; debug measurement is not substituted for required release characterization. The512MiB target cannot be precisely asserted from process-lifetime working set alone.

Safe data with fixture hashes: qa-admission.json. Private raw synthetic response HTML/results: .local/qa-admission; observer output: .local/logs/qa-admission.log. On rejection rows, server_parse_analysis_ms refers to retained previous analysis, not parsing time of rejected request; HTTP wall measures actual rejected request. Source code not modified by observer; candidate commit not frozen.

Browser helper now requires PLAYWRIGHT_MODULE and BROWSER_EXECUTABLE existing paths and supports BASE_URL / QA_BROWSER_OUTPUT. It checks actual selected origin including port. No packages/browsers installed; native Chrome path provided only through environment.
