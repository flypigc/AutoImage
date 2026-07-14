const readline = require('node:readline');
const cliProgress = require('cli-progress');

const BLUE = '\x1b[38;2;0;122;255m';
const RESET = '\x1b[0m';
const SAVE = '\x1b[s';
const RESTORE = '\x1b[u';
const CLEAR_LINE = '\x1b[2K';
const RESET_SCROLL_REGION = '\x1b[r';
const ANSI_PATTERN = /\x1b\[[0-9;]*m/g;

let lastLineCount = 0;
let spinner = null;
let oraFactoryPromise = null;

const barOptions = {
  barsize: 24,
  barCompleteString: '\u2588'.repeat(128),
  barIncompleteString: '\u2591'.repeat(128),
  barGlue: ''
};

function width() {
  return Math.max(40, (process.stdout.columns || 100) - 1);
}

function compactText(value, maxWidth) {
  const text = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (text.length <= maxWidth) {
    return text;
  }
  return maxWidth <= 3 ? text.slice(0, maxWidth) : `${text.slice(0, maxWidth - 3)}...`;
}

function percent(completed, total) {
  if (!total || total <= 0) {
    return 100;
  }
  return Math.min(100, Math.max(0, Math.floor((completed / total) * 100)));
}

function bar(value, size) {
  const safeSize = Math.max(4, size);
  const progress = Math.min(1, Math.max(0, value / 100));
  return cliProgress.Format.BarFormat(progress, {
    ...barOptions,
    barsize: safeSize
  });
}

function styledBar(value, size) {
  const raw = bar(value, size);
  const safeSize = Math.max(4, size);
  const progress = Math.min(1, Math.max(0, value / 100));
  const filled = Math.min(safeSize, Math.max(0, Math.floor(progress * safeSize)));

  if (filled <= 0) {
    return raw;
  }

  return `${BLUE}${raw.slice(0, filled)}${RESET}${raw.slice(filled)}`;
}

function stripAnsi(value) {
  return String(value ?? '').replace(ANSI_PATTERN, '');
}

function visibleLength(value) {
  return stripAnsi(value).length;
}

function padOrTrim(line, maxWidth) {
  if (visibleLength(line) <= maxWidth) {
    return `${line}${' '.repeat(maxWidth - visibleLength(line))}`;
  }

  const text = compactText(stripAnsi(line), maxWidth);
  return text.padEnd(maxWidth, ' ');
}

function isProgressVisible() {
  return lastLineCount > 0;
}

async function getOraFactory() {
  if (!process.stdout.isTTY) {
    return null;
  }

  if (!oraFactoryPromise) {
    oraFactoryPromise = import('ora')
      .then((module) => module.default)
      .catch(() => null);
  }

  return oraFactoryPromise;
}

function stopSpinnerSilently() {
  if (!spinner) {
    return;
  }

  spinner.stop();
  spinner = null;
}

async function startSpinner(event) {
  if (isProgressVisible()) {
    return;
  }

  const text = compactText(event.text, width());
  const ora = await getOraFactory();
  if (!ora) {
    if (text) {
      process.stdout.write(`${text}\n`);
    }
    return;
  }

  if (spinner) {
    spinner.text = text;
    return;
  }

  spinner = ora({
    text,
    color: 'blue',
    spinner: 'dots',
    discardStdin: false,
    stream: process.stdout
  }).start();
}

function updateSpinner(event) {
  if (!spinner) {
    return;
  }

  spinner.text = compactText(event.text, width());
}

function finishSpinner(method, event) {
  const text = compactText(event.text, width());
  if (!spinner) {
    if (text && !isProgressVisible()) {
      process.stdout.write(`${text}\n`);
    }
    return;
  }

  if (method === 'stop') {
    spinner.stop();
  } else {
    spinner[method](text);
  }
  spinner = null;
}

function resetScrollRegion() {
  if (!process.stdout.isTTY) {
    return '';
  }

  return RESET_SCROLL_REGION;
}

function cursorToBottom(lineCount) {
  const rows = process.stdout.rows || 0;
  const safeLineCount = Math.max(1, lineCount);
  const startRow = Math.max(1, rows - safeLineCount + 1);
  return `\x1b[${startRow};1H`;
}

function renderBottom(lines) {
  stopSpinnerSilently();

  const maxWidth = width();
  const visibleLines = lines.map((line) => padOrTrim(line, maxWidth));
  const clearCount = Math.max(lastLineCount, visibleLines.length);

  if (!process.stdout.isTTY) {
    if (visibleLines.length > 0) {
      process.stdout.write(`${visibleLines.join('\n')}\n`);
    }
    lastLineCount = visibleLines.length;
    return;
  }

  let output = `${SAVE}${cursorToBottom(clearCount)}`;
  for (let i = 0; i < clearCount; i += 1) {
    output += CLEAR_LINE;
    if (i < visibleLines.length) {
      output += visibleLines[i];
    }
    if (i < clearCount - 1) {
      output += '\n';
    }
  }
  output += resetScrollRegion();
  output += RESTORE;
  process.stdout.write(output);
  lastLineCount = visibleLines.length;
}

function renderSerial(event) {
  const terminalWidth = width();
  const barWidth = terminalWidth >= 120 ? 32 : terminalWidth >= 80 ? 24 : 16;
  const labelWidth = terminalWidth >= 120 ? 32 : terminalWidth >= 80 ? 24 : 16;
  const totalPercent = percent(event.totalCompleted, event.totalCount);
  const taskPercent = percent(event.subCompleted, event.subCount);
  const totalLabel = compactText(event.totalLabel, labelWidth);
  const taskLabel = compactText(event.subLabel, labelWidth);
  const statusWidth = Math.max(10, terminalWidth - barWidth - labelWidth - 22);
  const status = compactText(event.status, statusWidth);

  renderBottom([
    `${'TOTAL'.padEnd(5)} ${styledBar(totalPercent, barWidth)} ${String(totalPercent).padStart(3)}% ${totalLabel} ${event.totalCompleted}/${event.totalCount}`,
    `${'TASK'.padEnd(5)} ${styledBar(taskPercent, barWidth)} ${String(taskPercent).padStart(3)}% ${taskLabel} ${event.subCompleted}/${event.subCount}${status ? ` | ${status}` : ''}`
  ]);
}

function renderConcurrent(event) {
  const terminalWidth = width();
  const barWidth = terminalWidth >= 120 ? 24 : terminalWidth >= 80 ? 18 : 12;
  const totalPercent = percent(event.completedCount, event.totalCount);
  const status = compactText(event.currentStatus, Math.max(10, terminalWidth - barWidth - 56));
  const lines = [];

  lines.push(
    `${'TOTAL'.padEnd(5)} ${styledBar(totalPercent, barWidth)} ${String(totalPercent).padStart(3)}% done ${event.completedCount}/${event.totalCount} ok ${event.successCount} fail ${event.failedCount} queued ${event.queuedCount}${status ? ` | ${status}` : ''}`
  );
  lines.push(`IDX STATE    PROGRESS${' '.repeat(Math.max(1, barWidth - 8))} PCT  TIME   NAME`);

  const nameWidth = Math.max(8, terminalWidth - barWidth - 31);
  for (const task of event.tasks || []) {
    const taskPercent = Math.min(100, Math.max(0, Number(task.percent || 0)));
    lines.push(
      `${String(task.index).padStart(3)} ${String(task.state || '').padEnd(8)} ${styledBar(taskPercent, barWidth)} ${String(taskPercent).padStart(3)}% ${String(task.elapsed || '--').padStart(6)} ${compactText(task.name, nameWidth)}`
    );
  }

  if (event.hiddenCount && event.hiddenCount > 0) {
    lines.push(`... ${event.hiddenCount} more tasks`);
  }

  renderBottom(lines);
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity
});

async function handleLine(line) {
  if (!line.trim()) {
    return;
  }

  try {
    const event = JSON.parse(line);
    if (event.type === 'serial') {
      renderSerial(event);
    } else if (event.type === 'concurrent') {
      renderConcurrent(event);
    } else if (event.type === 'clear') {
      renderBottom([]);
    } else if (event.type === 'spinner:start') {
      await startSpinner(event);
    } else if (event.type === 'spinner:update') {
      updateSpinner(event);
    } else if (event.type === 'spinner:succeed') {
      finishSpinner('succeed', event);
    } else if (event.type === 'spinner:fail') {
      finishSpinner('fail', event);
    } else if (event.type === 'spinner:warn') {
      finishSpinner('warn', event);
    } else if (event.type === 'spinner:info') {
      finishSpinner('info', event);
    } else if (event.type === 'spinner:stop') {
      finishSpinner('stop', event);
    }
  } catch {
    // Progress rendering is best-effort; PowerShell keeps a fallback renderer.
  }
}

let eventQueue = Promise.resolve();
rl.on('line', (line) => {
  eventQueue = eventQueue.then(() => handleLine(line)).catch(() => {});
});

rl.on('close', () => {
  const output = `${SAVE}${cursorToBottom(Math.max(1, lastLineCount))}${resetScrollRegion()}${RESTORE}`;
  if (process.stdout.isTTY) {
    process.stdout.write(output);
  }
});
