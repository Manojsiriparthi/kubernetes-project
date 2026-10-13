const registrationForm = document.querySelector("#registration-form");
const lookupForm = document.querySelector("#lookup-form");
const registrationResult = document.querySelector("#registration-result");
const lookupResult = document.querySelector("#lookup-result");

function showError(container, message) {
  container.replaceChildren();
  const error = document.createElement("p");
  error.className = "result-error";
  error.textContent = message;
  container.append(error);
}

function renderStudent(student) {
  const card = document.createElement("article");
  card.className = "student-result";

  const name = document.createElement("h3");
  name.textContent = `${student.first_name} ${student.last_name}`;
  card.append(name);

  for (const detail of [
    `Hall ticket: ${student.hall_ticket}`,
    `Address: ${student.address}`,
    `Phone: ${student.phone}`,
    `Recent exam: ${student.recent_exam}`,
  ]) {
    const line = document.createElement("p");
    line.className = "student-meta";
    line.textContent = detail;
    card.append(line);
  }

  const marksTitle = document.createElement("p");
  marksTitle.className = "marks-title";
  marksTitle.textContent = `Subject marks · Total ${student.total}/500`;
  card.append(marksTitle);

  const marks = document.createElement("div");
  marks.className = "marks-list";
  for (const [subject, score] of Object.entries(student.marks)) {
    const chip = document.createElement("span");
    chip.className = "mark-chip";
    chip.textContent = `${subject}: ${score}`;
    marks.append(chip);
  }
  card.append(marks);
  return card;
}

registrationForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  registrationResult.textContent = "Registering student…";
  const student = Object.fromEntries(new FormData(registrationForm));
  try {
    const response = await fetch("/api/students", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(student),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Registration failed.");
    registrationResult.textContent = "Student registered successfully.";
    registrationForm.reset();
  } catch (error) {
    showError(registrationResult, error.message || "Could not reach the school service.");
  }
});

lookupForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  lookupResult.textContent = "Looking up student…";
  const form = new FormData(lookupForm);
  const params = new URLSearchParams({
    first_name: form.get("first_name"),
    last_name: form.get("last_name"),
  });
  try {
    const response = await fetch(`/api/students?${params}`);
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Student lookup failed.");
    if (result.students.length === 0) {
      showError(lookupResult, "No matching student found. Check the spelling or register the student first.");
      return;
    }
    lookupResult.replaceChildren(...result.students.map(renderStudent));
  } catch (error) {
    showError(lookupResult, error.message || "Could not reach the school service.");
  }
});
