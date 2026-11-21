# KeyBar

A small menu bar app for your Bluetooth keyboard.

Most wireless keyboards tell your Mac their battery level, and macOS never shows it. KeyBar does, along with how fast you type and a few other things worth knowing.

<p align="center">
  <img src="docs/popover.png" width="400" alt="The KeyBar popover: battery level and history, a typing speed chart, keystrokes and settings">
</p>

<p align="center">
  <a href="https://github.com/aryanranderiya/keybar/releases/latest/download/KeyBar.dmg"><b>Download KeyBar</b></a>
  &nbsp;·&nbsp; macOS 14 or later &nbsp;·&nbsp; Apple silicon and Intel
</p>

## What it shows

**Battery.** The real percentage, straight from the keyboard, plus roughly how many days you have left. Hover the chart to see the level at any point in the past week.

**Battery health.** After a few charges, KeyBar tells you how long a full charge really lasts, and how that compares with a few months ago. If 25 days has slipped to 15, you'll see it.

**A reminder to charge.** A notification a couple of days before the battery is likely to run out, based on how fast it usually drains. There are also plain alerts at 20%, 10% and 5%.

**Typing speed.** Your words per minute right now, and a chart of your day so far. It starts when you first typed and adjusts its detail to fit, minute by minute for a short session or in 5 or 15 minute steps over a long day. Hover for your speed at any point. After a day or two, switch to the last 7 or 30 days to see if you're getting faster.

**Keystrokes and corrections.** How much you've typed today, how long you spent typing, and how often you reached for Backspace.

**Auto-sleep** (Keychron). Keychron boards sleep after 10 minutes without a keypress. Once you stop typing, KeyBar counts down, so you know why the first key after a coffee break doesn't register.

**Details.** Firmware version, Bluetooth address, the rate the keyboard reports at, Caps Lock, and connect or disconnect in one click.

## Install

1. [Download KeyBar.dmg](https://github.com/aryanranderiya/keybar/releases/latest/download/KeyBar.dmg) and drag KeyBar into Applications.
2. Open it. macOS will say it can't verify the developer, because KeyBar isn't signed with a paid Apple developer account. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
3. Click the keycap icon in your menu bar and allow **Input Monitoring** when asked.

Input Monitoring is needed because your keyboard sends its battery level the same way it sends keypresses, so macOS treats reading one like reading the other. KeyBar only keeps counts and timings. It never stores which keys you pressed, and nothing leaves your Mac.

## Which keyboards work

Any keyboard connected over Bluetooth shows up, and typing stats work on all of them.

The battery level needs the keyboard to report it. Most do, using the standard Bluetooth battery report or the way Apple's Magic Keyboard does it. If yours doesn't, the battery card says so.

Tested on a Keychron K6.

## What it can't show

Some things stay inside the keyboard and are never sent to your Mac, so no app can read them:

- the backlight effect and brightness
- a Mac / Windows switch
- which Bluetooth slot you're on

## Build it yourself

You need Swift (Xcode or the Command Line Tools).

```sh
git clone https://github.com/aryanranderiya/keybar.git
cd keybar
./scripts/make-signing-cert.sh   # once, so Input Monitoring survives rebuilds
./scripts/build.sh --install
```

`./scripts/build.sh --release` builds for Apple silicon and Intel and packages `build/KeyBar.dmg`.

## License

MIT
