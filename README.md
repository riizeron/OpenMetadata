# OpenMetadata: сборка дистрибутива из готовых jar

Эта ветка собирает дистрибутив и Docker-образ OpenMetadata **без компиляции исходников**.
Все артефакты `org.open-metadata:*` берутся в опубликованном виде (Maven Central через Nexus),
а уязвимые транзитивные библиотеки заменяются на уровне Maven `dependencyManagement`.

Ветка отведена от upstream-тега `1.12.6-release`. Исходники upstream в дереве остаются как есть,
но в корневом [pom.xml](pom.xml) перечислены только три модуля сборки дистрибутива, поэтому
`openmetadata-service`, `openmetadata-ui`, `ingestion` и остальные модули Maven не трогает.
`bin/`, `conf/` и `bootstrap/` в tar.gz попадают прямо из дерева тега.

Версия upstream задаётся одним свойством `openmetadata.version` в [pom.xml](pom.xml).
Версия сборки (`ru.sber.datalake:omd-platform`) независима и имеет вид
`<openmetadata.version>-sber.N`, где `N` растёт с каждым патч-релизом.

## Как это работает

```
pom.xml                         список патчей: BOM-импорты и точечные пины версий
├── openmetadata-shaded-deps/   пересборка двух shaded-jar с поисковыми клиентами
│   ├── elasticsearch-dep/      org.open-metadata:elasticsearch-deps:<openmetadata.version>
│   └── opensearch-dep/         org.open-metadata:opensearch-deps:<openmetadata.version>
├── openmetadata-dist/          tar.gz: bin/ conf/ bootstrap/ libs/  + проверки classpath
├── openmetadata-docker/        Docker-образ из tar.gz
├── tools/check-dist.sh         jdeps, дубли классов, сравнение с libs.lock
├── bin/ conf/ bootstrap/       скрипты запуска, конфиг и SQL-миграции (из upstream-тега)
├── Jenkinsfile
└── openmetadata-service/, openmetadata-ui/, ingestion/, ...   исходники upstream, в reactor не входят
```

Отличия от тега, помимо файлов сборки: в `bin/openmetadata.sh` убрана битая строка
`CATALOG_HOME=$base_dirbase_dir=...`, `bootstrap/openmetadata-ops.sh` подключает
`conf/openmetadata-env.sh` и передаёт `$OPENMETADATA_OPTS` в JVM, демо-ключи `conf/*.der` удалены.

**Почему пинов в `dependencyManagement` достаточно.** Maven применяет `dependencyManagement`
модуля-потребителя ко всему транзитивному графу. Пин в корневом pom меняет версию библиотеки
во всех местах, где её тянет `openmetadata-service`, без правки upstream-овских pom.
Родительский pom сервиса (`org.open-metadata:platform`) берётся из Central как есть.

**Почему пересобираются `elasticsearch-deps` и `opensearch-deps`.** Upstream публикует их как
uber-jar с незарелоцированными копиями Jackson, HttpComponents 5, SLF4J и Jakarta JSON. Такие
копии нельзя обновить пином, и они перекрывают обычные jar на classpath. Модули собирают те же
jar с теми же relocations (`es.*`, `os.*`), но без этих библиотек. Координаты артефактов
совпадают с upstream, поэтому в reactor они подменяют опубликованные.

## Сборка

```bash
# дистрибутив + проверки (без Docker)
mvn -pl openmetadata-dist -am verify

# без UI
mvn -pl openmetadata-dist -am verify -DonlyBackend

# Docker-образ (нужен доступ к базовому образу и docker daemon)
mvn package -Ddocker.repo=<registry>
```

Результат: `openmetadata-dist/target/openmetadata-<version>.tar.gz`.

Требования: JDK 21, Maven 3.6+, `bash`, `unzip` (или `jar` из JDK) для проверок.

## Pipeline: package → verify → deploy

Три этапа, каждый это одна фаза Maven из корня репозитория. Maven всегда проходит жизненный цикл
с начала, поэтому `verify` повторяет `package`, а `deploy` повторяет оба: это плата за то, что
каждый этап самодостаточен и не зависит от способа вызова. Повтор стоит около 15 секунд, при этом
на этапе `deploy` в Nexus уходит ровно тот tar.gz, который прошёл проверки в том же вызове.

```bash
# 1. package: shaded-jar → tar.gz → docker build
mvn -B -ntp clean package -Ddocker.repo=$REGISTRY

# 2. verify: проверки classpath (jdeps, дубли, libs.lock, smoke-тесты)
mvn -B -ntp verify -Ddocker.repo=$REGISTRY

# 3. deploy: tar.gz в Nexus, push образа
mvn -B -ntp deploy -Ddocker.repo=$REGISTRY -Durl=$NEXUS_URL -DrepositoryId=$NEXUS_SERVER_ID
```

Порядок внутри reactor: shaded-модули → `openmetadata-dist` → `openmetadata-docker`. Образ не
собирается и не публикуется, если дистрибутив не прошёл проверки.

Флаги:

| Флаг | Действие |
|---|---|
| `-Ddocker.skip=true` | не собирать и не публиковать Docker-образ (штатный флаг fabric8), daemon не нужен |
| `-Dsmoke.skip=true` | пропустить проверки на `verify` |
| `-Dlock.mode=update` | пересчитать `libs.lock` и baseline дублей вместо сравнения |
| `-Ddocker.tag=<tag>` | тег образа, по умолчанию версия проекта |
| `-DonlyBackend` | дистрибутив без UI |

- `url` и `repositoryId` это стандартные параметры `deploy:deploy-file`; `repositoryId` должен
  совпадать с `<server><id>` в `settings.xml`, где лежат учётные данные Nexus. Без них Maven
  останавливает `deploy` сообщением о недостающем параметре.
- Артефакт в Nexus: `ru.sber.datalake:openmetadata:<version>:tar.gz:distrib`.
- Release-репозиторий не принимает одну версию дважды: перед публикацией поднимайте `-sber.N`.

## Проверки, встроенные в сборку

Выполняются на фазе `verify` модуля `openmetadata-dist`. Отключить: `-Dsmoke.skip=true`.

| Проверка | Что ловит |
|---|---|
| `OpenMetadataApplication check conf/openmetadata.yaml` на `target/libs` | главный класс не грузится, несовместимый Jackson, битый конфиг |
| jdeps по `openmetadata-service` | классы, на которые ссылается сервис, отсутствуют на classpath |
| `tools/JdbiAttachSmoke.java`: attach всех DAO-интерфейсов сервиса к JDBI над заглушкой JDBC | версия JDBI, под которую сервис не скомпилирован (`ClassCastException` на `Handler`); `check` до этого не доходит, миграции на стенде падают |
| дубли классов между jar | второй экземпляр библиотеки, который перекроет первый в зависимости от порядка `libs/*.jar` |
| `libs.lock` | любое изменение набора jar в дистрибутиве |
| `requireUpperBoundDeps` (только предупреждения в логе) | пин ниже версии, которую требует кто-то из зависимостей |

`openmetadata-dist/libs.lock` и `openmetadata-dist/duplicate-classes.baseline` лежат в git.
После **осознанного** изменения зависимостей обновите их и закоммитьте вместе с pom:

```bash
mvn -pl openmetadata-dist -am verify -Dlock.mode=update
```

Diff `libs.lock` в pull request показывает ревьюеру, что именно изменилось в runtime-наборе.
Baseline дублей это «храповик»: пары jar, которые пересекаются уже в upstream, допускаются,
новые пары валят сборку.

## Как добавить пин под CVE

1. Найдите артефакт в `libs.lock`, чтобы понять текущую версию.
2. Добавьте запись в `dependencyManagement` корневого pom с комментарием: upstream-версия и причина.
   Для семейств библиотек (Jackson, Jetty, Netty, JDBI, SLF4J) меняйте свойство BOM-импорта, а не отдельные артефакты.
3. `mvn -pl openmetadata-dist -am verify -Dlock.mode=update`, проверьте diff `libs.lock`.
4. Если библиотека упакована внутрь чужого jar, пин не поможет. См. «Ограничения».

Если пин требует `exclusions`, версию указывать обязательно: запись в `dependencyManagement`
полностью замещает запись из импортированного BOM, и без версии она станет пустой.

## Обновление версии OpenMetadata

1. Заберите новый тег и перенесите на него коммиты этой ветки:
   `git fetch origin tag <ver>-release && git rebase --onto <ver>-release 1.12.6-release`.
   Конфликты в `bin/`, `conf/`, `bootstrap/`, `openmetadata-shaded-deps/*/pom.xml` покажут,
   что именно upstream поменял в этих файлах; `bin/`, `conf/` и `bootstrap/` больше ни откуда
   копировать не нужно.
2. Сравните `properties` и `dependencyManagement` upstream-овского корневого `pom.xml` (в diff
   между тегами) с пинами в нашем корневом pom: пины, которые upstream уже подтянул, снимите.
3. Обновите `openmetadata.version` в корневом pom и `<version>` в
   `openmetadata-shaded-deps/*/pom.xml` (enforcer проверит совпадение).
4. Сверьте версии `elasticsearch-java` и `opensearch-java` с upstream-овскими
   `openmetadata-shaded-deps/*/pom.xml` из тега и обновите их.
5. Проверьте, не появились ли у upstream новые shaded-артефакты, которые тоже надо пересобирать.
6. `mvn -pl openmetadata-dist -am verify -Dlock.mode=update`, просмотрите diff.
7. Поднимите версию сборки до `<ver>-sber.1`.

## Ограничения подхода

- **openmetadata-ui** это webpack-бандл. JS-зависимости внутри него не патчатся без пересборки фронтенда.
- **Классы сервиса** скомпилированы под конкретные API библиотек. Наличие классов проверяет jdeps,
  но не совместимость их сигнатур. Известный случай: JDBI нельзя поднимать выше 3.37.x, с 3.38.0
  обработчики SqlObject перестали реализовывать `Handler`, и `handle.attach(MigrationDAO)` падает с
  `ClassCastException`. Для JDBI это ловит `JdbiAttachSmoke`; для других библиотек финальная проверка
  это запуск на стенде с БД.
- **Shaded-jar** упаковывают чужие библиотеки внутрь себя. Сейчас это два поисковых клиента, и они
  пересобираются здесь. При обновлении upstream список нужно перепроверять.

## Секреты

Ключи для подписи JWT (`conf/private_key.der`, `conf/public_key.der`) в репозитории **не хранятся**.
Upstream-овские демо-ключи публичны и не должны использоваться. Сгенерируйте пару под стенд и
передайте её через переменные окружения `RSA_PRIVATE_KEY_FILE_PATH` и `RSA_PUBLIC_KEY_FILE_PATH`
или смонтируйте в `conf/` контейнера:

```bash
openssl genrsa -out private_key.pem 2048
openssl pkcs8 -topk8 -inform PEM -outform DER -in private_key.pem -out private_key.der -nocrypt
openssl rsa -in private_key.pem -pubout -outform DER -out public_key.der
```
