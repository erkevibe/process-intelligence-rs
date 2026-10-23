# Повторная проверка свидетельств Sprint23

Команды запускаются из корня скачанного репозитория с Python 3. Каталоги вывода
должны быть новыми. Сначала закрепите точный Git commit и сверяйте весь архив:
хеш, записанный внутри пакета, сам по себе не удостоверяет его происхождение.

Публичный пакет содержит 192 файла: 16 919 608 исходных байт, 622 678 байт
хранимых частей, отдельно манифест. SHA-256 `transport-manifest.json`:
`912D1E5F25EC0CB9E2057ACDFDEF69DC898889246CC65E0E37EB3C5D30417CD1`.
Идентификатор исходной проверенной выборки:
`0E723F7BE2B611F69B2851B19812848DEF54C5B4A3BEBA773232E31945DEB858`.
Он служит меткой выборки, а не подписью строк манифеста.

```text
python tools/sprint23/evidence-transport.py verify evidence/sprint23 --workspace . --selection-sha 0E723F7BE2B611F69B2851B19812848DEF54C5B4A3BEBA773232E31945DEB858 --auditor tools/sprint23/audit-compact.py
python tools/sprint23/evidence-transport.py unpack evidence/sprint23 --output NEW_S23 --workspace . --selection-sha 0E723F7BE2B611F69B2851B19812848DEF54C5B4A3BEBA773232E31945DEB858 --auditor tools/sprint23/audit-compact.py
```

Пакет включает корпус, результаты и отчёты 90k, малые аварийные пары,
снимки браузера и отобранные квитанции. Пароли, сессии, резервные копии и
полные снимки базы не публикуются. Публичные квитанции с заменой локальных
путей имеют отдельный манифест проекции; исходные хеши процессов не заменены.
Поздние проверки отмены и чтения сборкой C05 описаны в отчёте отдельно;
этот ранее зафиксированный пакет не выдаётся за полный набор их сырых журналов.

Для полного сравнения 90k нужен исходный XES с SHA-256
`CBBD54489E7058054EBB4FD4091759024EA660129E736EF1F7C640C55F55BD8D`.
Его точные байты уже опубликованы в `evidence/sprint22/inputs/CMP90K.xes.gz`.
Восстановите весь старый пакет отдельной командой:

```text
python tools/sprint22/evidence-transport.py decode evidence/sprint22 NEW_S22 --workspace .
python tools/sprint23/audit-compact.py NEW_S23/90k/forward/report.json NEW_90K_AUDIT.json --source NEW_S22/inputs/CMP90K.xes --payload NEW_S23/90k/forward/payload.csv --oracle tools/oracle/audit-conversion-evidence.py --codec-sha 620468860F91B64AD21F64427E97EAFDCB3D50506236CA38315485B1C29004D4 --source-root . --from xes --to csv --require-compact --complexity CMP90K --inverse-report NEW_S23/90k/inverse/report.json --inverse-payload NEW_S23/90k/inverse/payload.xes
```

Аудит проверяет исходник, результат, полные упорядоченные поля и настоящую
обратную пару. Проверка упаковки и простое декодирование отчёта этого не доказывают.
Для корпуса заранее создайте пустой `NEW_CORPUS_AUDIT`:

```text
python tools/sprint23/audit-corpus.py NEW_S23/corpus NEW_CORPUS_AUDIT --auditor tools/sprint23/audit-compact.py --oracle tools/oracle/audit-conversion-evidence.py --corpus fixtures/conversions/corpus.json --source-root . --codec-sha 620468860F91B64AD21F64427E97EAFDCB3D50506236CA38315485B1C29004D4
```

Это повторный аудит сохранённых файлов. Он не запускает сервер, преобразователь
или PostgreSQL и не подменяет проверки аварии, браузера и доступа.
