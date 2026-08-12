import os
from flask import Flask, render_template, request, redirect, url_for, jsonify

app = Flask(__name__)

# In-memory store. Resets on restart -- fine for a demo app.
notes = []


@app.route("/", methods=["GET"])
def index():
    return render_template("index.html", notes=notes)


@app.route("/add", methods=["POST"])
def add():
    text = request.form.get("note", "").strip()
    if text:
        notes.append(text)
    return redirect(url_for("index"))


@app.route("/delete/<int:idx>", methods=["POST"])
def delete(idx):
    if 0 <= idx < len(notes):
        notes.pop(idx)
    return redirect(url_for("index"))


@app.route("/healthz")
def healthz():
    return jsonify(status="ok", notes=len(notes))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
