---
name: kvm-switch
description: Install, build, configure, and run the KVM Switch menu-bar app on a Mac. Use when the user wants to set up KVM Switch, share one keyboard/trackpad between two Macs over the network, build/launch "KVM Switch.app", grant its permissions, or pick the second Mac (peer). Triggers on "kvm switch", "поставь kvm", "запусти kvm switch", "переключение клавиатуры между маками".
---

# KVM Switch — установка и запуск

KVM Switch — menu-bar app для macOS: мгновенно переключает клавиатуру/трекпад между
двумя Mac по локальной сети (software KVM, не трогает Bluetooth). Симметрично: одно и
то же приложение на обоих Mac, каждый может отдавать и принимать ввод.

Эту папку (`kvm-switch/`) нужно поставить на **каждый** из двух Mac.

## Шаг 1. Проверить окружение

```sh
sw_vers                       # macOS 12+
xcode-select -p || xcode-select --install   # нужен Swift compiler
```

Если `xcode-select --install` — дождись установки Command Line Tools, потом продолжай.

## Шаг 2. Собрать приложение

Из директории этого скилла поднимись к корню проекта (где лежит `build.sh`) и собери:

```sh
cd "<путь к kvm-switch>"   # папка с build.sh, main.swift, Info.plist
./build.sh
```

Результат: `KVM Switch.app` рядом с `build.sh`. В архиве уже лежит собранный
`KVM Switch.app` — пересборка нужна, только если он не запускается (например, другая
архитектура Mac) или менялся код.

## Шаг 3. Запустить

```sh
open "KVM Switch.app"
```

В меню-баре появится иконка (🔴 — связи пока нет). Если иконки нет — почти всегда не
выданы права (Шаг 4) или приложение не успело стартовать; проверь процесс:

```sh
pgrep -fl "KVM Switch.app/Contents/MacOS"
```

## Шаг 4. Выдать права (обязательно)

Открой нужные панели System Settings и попроси пользователя добавить/включить
**KVM Switch** (кнопкой «+» добавить `KVM Switch.app`, если его нет в списке):

```sh
# Accessibility — обязательно (перехват и воспроизведение ввода)
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
# Input Monitoring — обязательно (перехват клавиатуры)
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
# Local Network — для авто-поиска второго Mac (обычно macOS спрашивает сам)
open "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
```

Это ручные GUI-шаги — Claude не может их кликнуть за пользователя. После включения
прав перезапусти приложение:

```sh
pkill -f "KVM Switch.app/Contents/MacOS"; open "KVM Switch.app"
```

## Шаг 5. Выбрать второй Mac (peer)

Сделать на ОБОИХ Mac (приложение должно работать на каждом):

- Кликнуть иконку в меню-баре → подменю **Второй Mac** → выбрать имя другого Mac
  (находится автоматически по сети).
- Если в списке пусто: проверь, что оба в одной Wi-Fi/LAN и оба приложения запущены;
  либо иконка → **Настройки…** → впиши IP второго Mac вручную (узнать его IP:
  `ipconfig getifaddr en0` на том Mac) и порт (по умолчанию 52333).

Когда связь поднимется, иконка станет 🟢.

## Шаг 6. Пользоваться

- Хоткей по умолчанию **⌃⌥⌘S** — ввод мгновенно уходит на второй Mac (иконка 🔵),
  ещё раз — назад (🟢). Сменить хоткей: Настройки… → Хоткей → нажать кнопку и набрать.
- Альтернатива хоткею: Настройки… → **Край экрана** (вкл + направление, где стоит
  второй Mac). Курсор переходит на крайнем ребре всех экранов; возврат — упереться в
  обратный край на втором Mac. Настроить на обоих Mac (зеркально: на одном «справа»,
  на другом «слева»).
- Автозапуск при логине: Настройки… → тумблер «Запускать автоматически».

## Состояния иконки

- 🔴 связи нет (второй Mac не выбран / выключен / нет прав)
- 🟢 связь есть, ввод на этом Mac
- 🔵 связь есть, ввод уходит на второй Mac

## Ограничения

Форвардятся курсор, клики, drag, two-finger scroll, клавиатура. Сложные мультитач-жесты
(свайпы Spaces, Mission Control, pinch) — нет. Это ограничение любого software-KVM.

## Диагностика

- Иконки нет → права не выданы (Шаг 4) или процесс не запущен (`pgrep`).
- Иконка 🔴, второй Mac выбран → проверь сеть, firewall (System Settings → Network →
  Firewall: «блокировать все входящие» должно быть выключено), один ли порт на обоих.
- Логи (если включён автозапуск): `/tmp/kvm-switch.log`.
