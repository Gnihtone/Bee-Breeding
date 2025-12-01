# Bee Breeder — Автоматический разводчик пчёл для GTNH

Программа для OpenComputers, автоматически выводящая любые виды пчёл в GregTech: New Horizons.

## Содержание

- [Требования](#требования)
- [Компоненты OpenComputers](#компоненты-opencomputers)
- [Устройства Forestry/GT](#устройства-forestrygt)
- [Схема подключения](#схема-подключения)
- [Настройка маркеров ролей](#настройка-маркеров-ролей)
- [Подготовка данных о пчёлах](#подготовка-данных-о-пчёлах)
- [Запуск программы](#запуск-программы)
- [Примеры использования](#примеры-использования)

---

## Требования

### Компоненты OpenComputers

| Компонент | Количество | Назначение |
|-----------|------------|------------|
| Computer Case (Tier 2+) | 1 | Основной компьютер |
| CPU (Tier 2+) | 1 | Процессор |
| Memory (Tier 2+) | 2 | Минимум 2 планки RAM |
| Hard Disk | 1 | Для хранения программы |
| EEPROM (Lua BIOS) | 1 | Загрузчик |
| Screen + Keyboard | 1 | Для взаимодействия |
| **Transposer** | 2-4 | Перемещение предметов |
| **Database** | 1 | Для работы с ME |
| **Adapter** | 1 | Подключение к Apiary |

### Устройства Forestry/GT

| Устройство | Количество | Назначение |
|------------|------------|------------|
| Forestry Apiary | 1 | Разведение пчёл |
| Forestry Analyzer | 1 | Анализ пчёл |
| Acclimatizer | 1 | Акклиматизация пчёл |
| ME Interface | 2 | Для пчёл и блоков |
| Chest/Drawer | 4+ | Буферы |

---

## Схема подключения

```
                    ┌─────────────────┐
                    │   ME Network    │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
    ┌─────────┴─────────┐         ┌────────┴────────┐
    │ ME Interface      │         │ ME Interface    │
    │ (ROLE:ME-BEES)    │         │ (ROLE:ME-BLOCKS)│
    └─────────┬─────────┘         └────────┬────────┘
              │                             │
              │ Transposer                  │ Transposer
              │                             │
    ┌─────────┴─────────┐         ┌────────┴────────┐
    │ Chest             │         │ Chest           │
    │ (ROLE:BUFFER)     │         │ (ROLE:FOUNDATION)│
    └─────────┬─────────┘         └─────────────────┘
              │
              │ Transposer (центральный)
              │
    ┌─────────┼─────────┬─────────────────┐
    │         │         │                 │
    ▼         ▼         ▼                 ▼
┌───────┐ ┌───────┐ ┌───────┐       ┌───────────┐
│Apiary │ │Analyzer│ │Accli- │       │ Chest     │
│       │ │       │ │matizer│       │(ROLE:TRASH)│
└───────┘ └───────┘ └───────┘       └───────────┘
                          │
                          │ Transposer
                          │
                    ┌─────┴─────┐
                    │ Chest     │
                    │(ROLE:     │
                    │ACCL-MATS) │
                    └───────────┘
```

### Важно!

- **Transposer** должен касаться всех устройств, между которыми нужно перемещать предметы
- Один Transposer может обслуживать до 6 сторон
- Apiary, Analyzer, Acclimatizer и Buffer должны быть на одном Transposer
- ME Interface подключается через отдельный Transposer к Buffer

---

## Настройка маркеров ролей

Программа определяет устройства по **маркерам** — предметам в **слоте 1** сундука/интерфейса.

### Как создать маркер

1. Возьмите любой предмет (например, бумагу)
2. Переименуйте на наковальне в нужную роль
3. Положите в **слот 1** соответствующего сундука

### Список ролей

| Роль | Куда положить | Назначение |
|------|---------------|------------|
| `ROLE:BUFFER` | Основной сундук | Буфер для разведения |
| `ROLE:TRASH` | Сундук для мусора | Сюда идут гибриды |
| `ROLE:ACCL-MATS` | Сундук с реагентами | Ice, Blaze Rod, Sand, Water Can |
| `ROLE:FOUNDATION` | Сундук для блоков | Блоки-фундаменты для игрока |
| `ROLE:ME-BEES` | ME Interface конфиг слот 1 | Интерфейс для пчёл |
| `ROLE:ME-BLOCKS` | ME Interface конфиг слот 1 | Интерфейс для блоков |

### Настройка ME Interface маркера

Для ME Interface маркер ставится в **конфигурацию слота 1**:

1. Откройте ME Interface
2. В верхней части (конфигурация) в слот 1 поставьте призрак предмета с названием роли
3. Или используйте бумагу с названием роли

---

## Подготовка данных о пчёлах

Перед первым запуском нужно экспортировать данные о мутациях:

### Шаг 1: Экспорт данных

```bash
# Запустите на компьютере с подключённым Apiary
export_bee_data
```

Это создаст два файла:
- `bee_mutations.txt` — все возможные мутации
- `bee_requirements.txt` — климат/влажность для каждого вида

### Шаг 2: Проверка файлов

```bash
# Проверить что файлы созданы
ls
```

Должны быть:
```
bee_mutations.txt
bee_requirements.txt
main.lua
... (остальные файлы программы)
```

---

## Запуск программы

### Показать справку

```bash
main
```

### Вывести конкретный вид

```bash
main Industrious
```

Программа автоматически:
1. Проверит что есть в ME
2. Построит путь мутаций
3. Выведет все необходимые промежуточные виды
4. Выведет целевой вид

### Вывести все доступные виды

```bash
main all
```

Программа работает **волнами**:
1. Находит виды, которые можно вывести из уже готовых (одна мутация)
2. Выводит их все
3. Повторяет, пока есть что выводить

Это умнее чем перебор всех видов — программа не пытается вывести вид, для которого нет родителей.

---

## Примеры использования

### Пример 1: Вывести Industrious

```bash
main Industrious
```

Вывод:
```
=== Bee Breeder Initializing ===
Discovering devices...
  Found 1 apiary(s)
  Found 1 analyzer(s)
  Found 1 acclimatizer(s)
Loading bee data...
  Loaded 150 mutations
  Loaded 150 requirements
=== Initialization Complete ===

=== [1/1] Breeding Industrious ===
Checking Industrious...
  Stock: 0 princess, 0 drones
  → Mutating from Common + Cultivated...
  Checking Common...
    Stock: 1 princess, 30 drones
    → Breeding more drones...
    Starting mutation: Common + Common → Common
    ...
  Checking Cultivated...
    ...
Starting mutation: Common + Cultivated → Industrious
  Requirements: climate=Normal, humidity=Normal, block=none
  Loaded initial bees
  Cycle 1...
    Target: 5 drones, princess: no
  Cycle 2...
    ...
  Goal reached for Industrious!
  Sorting complete
Industrious complete!

=== All Done! ===
```

### Пример 2: Вывести все доступные виды

```bash
main all
```

Вывод:
```
=== Wave 1: Finding achievable species ===
Found 3 species to breed:
  1. Common (Forest + Meadows)
  2. Cultivated (Common + Diligent)
  3. Noble (Common + Diligent)

--- [1/3] Breeding Common ---
...
Common complete!

--- [2/3] Breeding Cultivated ---
...

=== Wave 2: Finding achievable species ===
Found 5 species to breed:
  1. Industrious (Common + Cultivated)
  ...

=== All Done! Bred 15 species total ===
```

### Пример 3: Показать справку

```bash
main
```

Вывод:
```
Bee Breeder - Automatic bee breeding for GTNH

Usage:
  main <species>  - breed a specific species (e.g., main Industrious)
  main all        - breed all achievable species from current stock

Before first run:
  export_bee_data - export mutation data from apiary
...
```

---

## Реагенты для акклиматизации

Положите в сундук `ROLE:ACCL-MATS`:

| Реагент | Для климата/влажности |
|---------|----------------------|
| Blaze Rod | HOT, WARM, HELLISH |
| Ice | COLD, ICY |
| Water Can | DAMP |
| Sand | ARID |

---

## Блоки-фундаменты

Некоторые мутации требуют специальный блок под Apiary.

Программа автоматически выдаст нужный блок в сундук `ROLE:FOUNDATION`.
**Вам нужно вручную** поставить его под Apiary.

---

## Структура файлов

```
/home/
├── main.lua              # Главный файл (запуск)
├── orchestrator.lua      # Координатор разведения
├── apiary_proc.lua       # Работа с Apiary
├── analyzer_proc.lua     # Работа с Analyzer
├── acclimatizer_proc.lua # Работа с Acclimatizer
├── foundation.lua        # Выдача блоков-фундаментов
├── pathfinder.lua        # Построение пути мутаций
├── discovery.lua         # Обнаружение устройств
├── mover.lua             # Перемещение предметов
├── utils.lua             # Общие функции
├── analyzer.lua          # Анализ пчёл (чистота, вид)
├── bee_stock.lua         # Учёт запасов в ME
├── bee_data_parser.lua   # Парсер данных о пчёлах
├── me_interface.lua      # Работа с ME сетью
├── export_bee_data.lua   # Экспорт данных (запустить 1 раз)
├── bee_mutations.txt     # Данные о мутациях (генерируется)
└── bee_requirements.txt  # Данные о требованиях (генерируется)
```

---

## Troubleshooting

### "No apiary found"
Убедитесь что Adapter касается Apiary.

### "Missing required device: ROLE:BUFFER"
Положите маркер `ROLE:BUFFER` в слот 1 основного сундука.

### "No donor princess available"
Нет лишних принцесс для конвертации. Нужно сначала вывести базовые виды (Forest, Meadows).

### "Base species X not available and cannot be mutated"
У вас нет базового вида (Forest, Meadows, etc.) и его нельзя вывести мутацией.
Найдите его в мире и положите в ME.

### "reagent depleted: Blaze Rod"
Закончились реагенты. Пополните сундук `ROLE:ACCL-MATS`.

---

## Советы

1. **Начните с базовых видов** — убедитесь что в ME есть Forest, Meadows, и другие базовые виды (по 1 принцессе + 64 дрона)

2. **Держите запас реагентов** — положите много Ice, Blaze Rod, Sand, Water Can

3. **Следите за фундаментами** — когда программа выдаёт блок в FOUNDATION, поставьте его под Apiary

4. **Используйте Alveary** — для ускорения можно заменить Apiary на Alveary (программа поддерживает оба)

---

## Лицензия

MIT — используйте как хотите!

