// DOM tests for app.js: load the real index.html in jsdom, replace fetch with a fake, and submit the forms.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { JSDOM } = require("jsdom");

const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const script = fs.readFileSync(path.join(__dirname, "..", "app.js"), "utf8");

// Loads the page and runs app.js with the given fake fetch.
function loadPage(fakeFetch) {
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "http://localhost/" });
  dom.window.fetch = fakeFetch;
  dom.window.eval(script);
  return dom.window;
}

function fillAndSubmit(window, formId, values) {
  const form = window.document.querySelector(formId);
  for (const [name, value] of Object.entries(values)) {
    form.elements[name].value = value;
  }
  form.dispatchEvent(new window.Event("submit", { cancelable: true, bubbles: true }));
}

// The submit handlers are async; give the fake fetch promises a moment to settle.
const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

const ananya = {
  first_name: "Ananya",
  last_name: "Rao",
  class_name: "10",
  address: "12 Lake View Road",
  phone: "9000000101",
  father_phone: "9000000201",
  hall_ticket: "SCI-2026-00101",
  recent_exam: "Term 1",
  marks: { Telugu: 91, English: 88, Maths: 96, Science: 93, Social: 89 },
  total: 457,
};

test("lookup renders the student card with marks", async () => {
  let requestedUrl = "";
  const window = loadPage(async (url) => {
    requestedUrl = url;
    return { ok: true, json: async () => ({ students: [ananya] }) };
  });

  fillAndSubmit(window, "#lookup-form", { first_name: "Ananya", last_name: "Rao", class_name: "10" });
  await settle();

  assert.match(requestedUrl, /^\/api\/students\?/);
  assert.match(requestedUrl, /first_name=Ananya/);
  const result = window.document.querySelector("#lookup-result");
  assert.match(result.textContent, /Ananya Rao/);
  assert.match(result.textContent, /SCI-2026-00101/);
  assert.match(result.textContent, /Total 457\/500/);
  assert.equal(result.querySelectorAll(".mark-chip").length, 5);
  assert.equal(result.querySelectorAll(".mark-bar").length, 5);
});

test("lookup shows a friendly message when nothing matches", async () => {
  const window = loadPage(async () => ({ ok: true, json: async () => ({ students: [] }) }));

  fillAndSubmit(window, "#lookup-form", { first_name: "No", last_name: "One", class_name: "1" });
  await settle();

  assert.match(window.document.querySelector("#lookup-result .result-error").textContent, /No matching student/);
});

test("lookup shows the server error message", async () => {
  const window = loadPage(async () => ({ ok: false, json: async () => ({ error: "Student records are temporarily unavailable." }) }));

  fillAndSubmit(window, "#lookup-form", { first_name: "A", last_name: "B", class_name: "1" });
  await settle();

  assert.match(window.document.querySelector("#lookup-result").textContent, /temporarily unavailable/);
});

test("registration posts JSON and reports success", async () => {
  let request;
  const window = loadPage(async (url, options) => {
    request = { url, options };
    return { ok: true, json: async () => ({ student: ananya }) };
  });

  fillAndSubmit(window, "#registration-form", {
    first_name: "Ananya",
    last_name: "Rao",
    class_name: "10",
    address: "12 Lake View Road",
    phone: "9000000101",
    father_phone: "9000000201",
  });
  await settle();

  assert.equal(request.url, "/api/students");
  assert.equal(request.options.method, "POST");
  assert.equal(JSON.parse(request.options.body).last_name, "Rao");
  assert.match(window.document.querySelector("#registration-result").textContent, /registered successfully/);
});

test("registration shows an error when the service is unreachable", async () => {
  const window = loadPage(async () => {
    throw new Error("network down");
  });

  fillAndSubmit(window, "#registration-form", {
    first_name: "A",
    last_name: "B",
    class_name: "1",
    address: "x",
    phone: "1",
    father_phone: "2",
  });
  await settle();

  assert.match(window.document.querySelector("#registration-result .result-error").textContent, /network down/);
});
