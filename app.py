import os
from flask import Flask, render_template, request, redirect, url_for, jsonify

app = Flask(__name__)

# From the chart's ConfigMap (config.env in values.yaml), injected with envFrom.
# Defaults keep `python app.py` working with no environment at all.
APP_TITLE = os.environ.get("APP_TITLE", "Notes")
APP_ENV = os.environ.get("APP_ENV", "dev")

# In-memory store. Resets on restart -- fine for a demo app.
notes = []


@app.route("/", methods=["GET"])
def index():
    return render_template("index.html", notes=notes, title=APP_TITLE, env=APP_ENV)


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
    # title/env echo the ConfigMap back, so `curl /healthz` is enough to prove
    # the ConfigMap reached the pod -- no exec into the container.
    return jsonify(status="ok", notes=len(notes), title=APP_TITLE, env=APP_ENV)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8090)))
