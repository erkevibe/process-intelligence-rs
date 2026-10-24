# Самостоятельная проверка отчёта

Этот комплект проверяет сохранённые файлы XES ↔ CSV. Он работает без сервера,
PostgreSQL, подключения к сети и установки библиотек. Используйте Python 3.13 —
эта версия проверена локально. Отдельные проверки выполняются также в среде CI.

Сохраните три файла из одного преобразования: исходный журнал, результат и отчёт.
Отчёт без исходника и результата не доказывает правильность преобразования.
Для проверки нужны доступные вам локальные файлы; комплект ничего не загружает.

## Что находится в архиве

В `checker-kit.zip` ровно пять файлов: декодер `tools/sprint23/decode-report.py`,
проверяющий `tools/sprint23/audit-compact.py`, обязательный независимый разборщик
`tools/oracle/audit-conversion-evidence.py`, эта инструкция и `SHA256SUMS`.
Последний содержит SHA-256 четырёх остальных файлов. Сверяйте также хеш архива
с закреплённым Git commit: список хешей внутри архива сам по себе не подтверждает
происхождение. Распакуйте архив целиком, сохранив папки.

Следующие команды запускаются из папки распакованного комплекта. Вместо
`INPUT.xes`, `RESULT.csv` и `REPORT.json` укажите свои три файла. Все новые
выходные имена должны находиться в существующей папке и ещё не существовать.
Пути с пробелами заключайте в двойные кавычки.

## 1. Проверить исходник, результат и полный отчёт

Для XES → CSV:

```text
python -I -B tools/sprint23/audit-compact.py REPORT.json NEW_AUDIT.json --source INPUT.xes --payload RESULT.csv --oracle tools/oracle/audit-conversion-evidence.py --codec-sha 620468860F91B64AD21F64427E97EAFDCB3D50506236CA38315485B1C29004D4 --from xes --to csv
```

Для CSV → XES поменяйте направления и имена файлов:

```text
python -I -B tools/sprint23/audit-compact.py REPORT.json NEW_AUDIT.json --source INPUT.csv --payload RESULT.xes --oracle tools/oracle/audit-conversion-evidence.py --codec-sha 620468860F91B64AD21F64427E97EAFDCB3D50506236CA38315485B1C29004D4 --from csv --to xes
```

Команды принимают обычный отчёт schema 1 и компактный schema 2. Для schema 2
флаг `--require-compact` дополнительно запрещает подмену обычным форматом.
Если исходное преобразование явно разрешало потерю метаданных, добавьте
`--allow-loss`; проверяющий сверяет полный заявленный инвентарь потерь.
Не добавляйте этот флаг только ради обхода отказа.

При успехе `NEW_AUDIT.json` содержит статус
`INDEPENDENT_COMPACT_REPORT_DIRECT_SOURCE_PAYLOAD_AUDIT_PASS`.
Название статуса общее для обоих форматов; поле `encoding.stored_schema`
показывает фактически проверенный формат. Проверяются хеши и размеры файлов,
поля событий и их порядок, предупреждения и заявленные преобразования.
При отказе команда завершается с ненулевым кодом. Существующий выходной файл
не перезаписывается. Не считайте старый файл результатом неудачного запуска.

## 2. Прочитать компактный отчёт как обычный JSON

```text
python -I -B tools/sprint23/decode-report.py REPORT.json NEW_LOGICAL_REPORT.json --codec-sha 620468860F91B64AD21F64427E97EAFDCB3D50506236CA38315485B1C29004D4
```

Декодер предназначен только для компактного отчёта. Он восстанавливает точные
байты полного JSON и проверяет его оболочку; сам по себе он не сравнивает
исходник с результатом. Обычный отчёт schema 1 уже является полным JSON.

## 3. При наличии обратного преобразования

К команде первого шага добавьте оба файла настоящего обратного преобразования:

```text
--inverse-report INVERSE_REPORT.json --inverse-payload INVERSE_RESULT.xes
```

Для исходного направления CSV → XES обратный результат имеет формат CSV.
Проверяющий сравнит возвращённые поля с исходными. Он читает предоставленные
файлы и не запускает преобразователь. Это не доказательство запуска процесса,
его кода завершения, браузерной работы, прав доступа или аварийного восстановления.

## Границы проверки

Пределы сохранены: отчёт до 4 MiB, распакованный JSON до 64 MiB, исходник и
результат до 20 MiB каждый. Поддерживается конечный профиль XES ↔ CSV проекта,
а не любой XML, весь BPMN/PNML или полная совместимость с Apromore.

Хеш кодека выше относится к этой версии исходника, не является подписью и не
подтверждает издателя. Проверка без `--source-root` не сверяет весь исходный
checkout; поле `source_provenance_files_checked` остаётся false. Сохранённые
журналы процессов и полная резервная копия базы — отдельные свидетельства.

## Лицензия инструментов

MIT License

Copyright (c) 2026 erkevibe

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
