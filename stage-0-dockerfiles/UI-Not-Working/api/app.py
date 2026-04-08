import os
import json
import psycopg2
from flask import Flask, request, jsonify
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

def get_db():
    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=os.environ.get("DB_PORT", 5432),
        database=os.environ.get("DB_NAME", "todos"),
        user=os.environ.get("DB_USER", "postgres"),
        password=os.environ.get("DB_PASSWORD", "secret"),
    )

def init_db():
    conn = get_db()
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS todos (
            id SERIAL PRIMARY KEY,
            title TEXT NOT NULL,
            done BOOLEAN DEFAULT FALSE,
            created_at TIMESTAMP DEFAULT NOW()
        )
    """)
    conn.commit()
    cur.close()
    conn.close()

@app.route("/health")
def health():
    return jsonify({"status": "ok", "service": "api"})

@app.route("/todos", methods=["GET"])
def list_todos():
    conn = get_db()
    cur = conn.cursor()
    cur.execute("SELECT id, title, done FROM todos ORDER BY created_at DESC")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify([{"id": r[0], "title": r[1], "done": r[2]} for r in rows])

@app.route("/todos", methods=["POST"])
def create_todo():
    data = request.get_json()
    conn = get_db()
    cur = conn.cursor()
    cur.execute("INSERT INTO todos (title) VALUES (%s) RETURNING id", (data["title"],))
    todo_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({"id": todo_id, "title": data["title"], "done": False}), 201

@app.route("/todos/<int:todo_id>", methods=["PATCH"])
def update_todo(todo_id):
    data = request.get_json()
    conn = get_db()
    cur = conn.cursor()
    cur.execute("UPDATE todos SET done=%s WHERE id=%s", (data["done"], todo_id))
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({"id": todo_id, "done": data["done"]})

@app.route("/todos/<int:todo_id>", methods=["DELETE"])
def delete_todo(todo_id):
    conn = get_db()
    cur = conn.cursor()
    cur.execute("DELETE FROM todos WHERE id=%s", (todo_id,))
    conn.commit()
    cur.close()
    conn.close()
    return "", 204

if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=5000, debug=os.environ.get("FLASK_DEBUG", "false") == "true")
