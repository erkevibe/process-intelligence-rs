# Папки внутри проекта

Ручной контракт S8-P2 фиксируется до реализации. Это спецификация, а не свидетельство приёмки.

`Organization` хранит `folders: BTreeMap<folder_id, Folder>` и `assignments: BTreeMap<resource_id, folder_id>`. Пустая организация — default; Root интегрирует пропуск пустого поля в прежний Header. `Folder` содержит `name` и необязательный `parent`. Неизвестные поля отклоняются. Папки принадлежат ровно одному snapshot проекта, а разрешённый каталог ресурсов передаёт вызывающий код этого проекта. В модуле нет глобального каталога, пользователя, database или переноса между проектами.

ID папки — `folder-` и UUIDv4/RFC4122 в канонической lowercase форме с дефисами. Root создаёт новые UUID; модуль принимает переданный ID и никогда не меняет его при rename/move. Максимум128папок. Команды обрезают пробелы по краям имени; сохранённый snapshot должен уже содержать каноническое имя. Имя1–200UTF8bytes. У одного родителя, включая корень, не допускаются одинаковые имена. Сравнение точное, регистрозависимое; Unicode NFC и case-fold не выполняются.

Родитель должен существовать в том же snapshot. Self-parent и циклы любой длины запрещены. Папка удаляется только без дочерних папок и назначенных ресурсов; назначение не меняет ID или payload ресурса. `assign(resource,None)` возвращает существующий ресурс в корень. Неизвестный/чужой resource ID, отсутствующий folder ID, dangling assignments и resource IDs длиннее128bytes отклоняются. Внешний current-project каталог — обязательный аргумент всех команд. Удаление, archive и права проекта выполняет Root вне чистого модуля.

API: `validate(catalog)`, `is_empty()`, `create(id,name,parent,catalog)`, `rename(id,name,catalog)`, `move_folder(id,parent,catalog)`, `delete_empty(id,catalog)`, `assign(resource_id,folder_or_none,catalog)`. Каждая команда сначала валидирует текущий snapshot, затем изменяет копию, полностью валидирует результат и только после успеха заменяет snapshot. Ошибка не оставляет частичного изменения. Долговечность и optimistic CAS по revision всего repository обеспечивает Root; отдельной folder revision нет.

Ошибка | Условие
---|---
`folder_policy` | malformed ID/имя, >128папок, неканоническое сохранённое имя
`folder_parent` | отсутствующий родитель или self-parent
`folder_duplicate` | повторный ID либо одинаковое sibling имя
`folder_cycle` | цикл родителей
`folder_missing` | неизвестная папка для команды или назначения
`folder_not_empty` | удаление с детьми/назначенными ресурсами
`folder_resource` | отсутствующий в current-project каталоге ресурс/dangling assignment

## Literal ожидания до кода

Разрешённый каталог `{log-1, model-2}`. A=`folder-00000000-0000-4000-8000-000000000001`, B=`folder-00000000-0000-4000-8000-000000000002`.

- CreateA name`  Главная  ` в корне → сохранено`Главная`. CreateB`Дочерняя` parentA, assignlog-1→B → два stableID и одно назначение.
- RenameB→`Переименована`, moveB→корень → те же IDs и assignmentlog-1→B. Assignlog-1→None → assignment удалён, ресурс остаётся в каталоге.
- Две root папки с именем`Same` → `folder_duplicate`. `Same` и `same` разрешены; одинаковые имена под разными родителями разрешены.
- Literal snapshot A.parentB/B.parentA → `folder_cycle`. A.parentA→`folder_parent`; A.parent missing→`folder_parent`.
- Literal assignments `{log-999:A}` при каталоге `{log-1,model-2}` → `folder_resource`; `{log-1:missing}` → `folder_missing`.
- DeleteA при ребёнкеB или назначенииlog-1→A → `folder_not_empty`; после явного unassign и удаления пустогоB разрешено deleteA.
- MoveA под собственного потомкаB, rename в duplicate sibling, assign чужогоlog-999, create129-й папки, malformedUUID, пустое/201byte имя → отказ и полный snapshot `==` исходному.
- Backup/restore/restart/RBAC/CAS/сохранение payload являются интеграционными критериями Root/независимых QA, а не возможностями чистого модуля и не доказаны этими unit fixtures.

Frozen executable manual fixtures: `tests/sprint08_folders.rs`. До реализации их raw SHA передаётся Root. Независимый QA/TD проверяет итоговый кандидат; автор модуля не принимает собственный код.
