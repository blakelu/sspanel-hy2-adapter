package auth

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

var databaseCredentialFields = map[string]string{
	"uuid":      "u.uuid",
	"passwd":    "u.passwd",
	"email":     "u.email",
	"user_name": "u.user_name",
}

type Database struct {
	db     *sql.DB
	query  string
	args   int
	nodeID int64
}

func OpenDatabase(ctx context.Context, dsn string, nodeID int64, fields []string, maxOpen, maxIdle int, maxLifetime time.Duration) (*Database, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	db.SetMaxOpenConns(maxOpen)
	db.SetMaxIdleConns(maxIdle)
	db.SetConnMaxLifetime(maxLifetime)
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}

	conditions := make([]string, 0, len(fields))
	for _, field := range fields {
		column, ok := databaseCredentialFields[field]
		if !ok {
			db.Close()
			return nil, fmt.Errorf("unsupported database credential field %q", field)
		}
		conditions = append(conditions, column+" = ?")
	}
	query := `SELECT u.id
FROM ` + "`user`" + ` AS u
INNER JOIN ` + "`node`" + ` AS n ON n.id = ?
WHERE n.type <> 0
  AND (n.node_bandwidth_limit = 0 OR n.node_bandwidth < n.node_bandwidth_limit)
  AND (` + strings.Join(conditions, " OR ") + `)
  AND (
    u.is_admin = 1
    OR (
      u.is_banned = 0
      AND u.class_expire > NOW()
      AND u.class >= n.node_class
      AND (n.node_group = 0 OR u.node_group = n.node_group)
      AND u.transfer_enable > u.u + u.d
    )
  )
LIMIT 2`
	return &Database{db: db, query: query, args: len(fields), nodeID: nodeID}, nil
}

func (d *Database) Authenticate(ctx context.Context, credential string) (int64, bool, error) {
	args := make([]any, 0, d.args+1)
	args = append(args, d.nodeID)
	for i := 0; i < d.args; i++ {
		args = append(args, credential)
	}
	rows, err := d.db.QueryContext(ctx, d.query, args...)
	if err != nil {
		return 0, false, fmt.Errorf("query user: %w", err)
	}
	defer rows.Close()
	var id int64
	if !rows.Next() {
		return 0, false, rows.Err()
	}
	if err := rows.Scan(&id); err != nil {
		return 0, false, fmt.Errorf("scan user: %w", err)
	}
	if rows.Next() {
		return 0, false, nil
	}
	return id, true, rows.Err()
}

func (d *Database) Healthy() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return d.db.PingContext(ctx) == nil
}

func (d *Database) Close() error { return d.db.Close() }

func NewDatabase(ctx context.Context, dsn string, nodeID int64, fields []string, maxOpen, maxIdle int, maxLifetime time.Duration) (Source, error) {
	db, err := OpenDatabase(ctx, dsn, nodeID, fields, maxOpen, maxIdle, maxLifetime)
	if err != nil {
		return nil, err
	}
	return db, nil
}
