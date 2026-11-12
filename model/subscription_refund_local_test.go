package model

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/mysql"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

// These tests require disposable databases, never the live billing database.
func TestLocalSubscriptionRefundMatrix(t *testing.T) {
	for _, dialect := range []string{"sqlite", "mysql", "postgres"} {
		t.Run(dialect, func(t *testing.T) {
			var driver gorm.Dialector
			switch dialect {
			case "sqlite":
				dsn := filepath.ToSlash(filepath.Join(t.TempDir(), "refund.db")) + "?_pragma=busy_timeout(500)&_pragma=journal_mode(WAL)&_txlock=immediate"
				driver = sqlite.Open(dsn)
			case "mysql":
				dsn := os.Getenv("TEST_MYSQL_DSN")
				if dsn == "" {
					if os.Getenv("LOCAL_REFUND_REQUIRE_MATRIX") == "1" {
						t.Fatal("TEST_MYSQL_DSN is required")
					}
					t.Skip("TEST_MYSQL_DSN is not configured")
				}
				driver = mysql.Open(dsn)
			case "postgres":
				dsn := os.Getenv("TEST_POSTGRES_DSN")
				if dsn == "" {
					if os.Getenv("LOCAL_REFUND_REQUIRE_MATRIX") == "1" {
						t.Fatal("TEST_POSTGRES_DSN is required")
					}
					t.Skip("TEST_POSTGRES_DSN is not configured")
				}
				driver = postgres.Open(dsn)
			}
			db, err := gorm.Open(driver, &gorm.Config{})
			require.NoError(t, err)
			sqlDB, err := db.DB()
			require.NoError(t, err)
			sqlDB.SetMaxOpenConns(4)
			previousDB, previousType := DB, common.MainDatabaseType()
			DB = db
			common.SetMainDatabaseType(common.DatabaseType(dialect))
			initCol()
			t.Cleanup(func() {
				DB = previousDB
				common.SetMainDatabaseType(previousType)
				initCol()
				assert.NoError(t, sqlDB.Close())
			})
			require.NoError(t, db.AutoMigrate(&UserSubscription{}, &SubscriptionPreConsumeRecord{}))
			query := "SELECT version()"
			if dialect == "sqlite" {
				query = "SELECT sqlite_version()"
			}
			var version string
			require.NoError(t, db.Raw(query).Scan(&version).Error)
			t.Logf("database version: %s", version)

			t.Run("refund_once_and_duplicate", func(t *testing.T) {
				sub, records := seedLocalRefund(t, db, 1)
				require.NoError(t, RefundSubscriptionPreConsume(records[0].RequestId))
				require.NoError(t, RefundSubscriptionPreConsume(records[0].RequestId))
				assertLocalRefund(t, db, sub.Id, records, 100, "refunded")
			})
			t.Run("record_failure_rolls_back_quota", func(t *testing.T) {
				sub, records := seedLocalRefund(t, db, 1)
				injected := errors.New("injected refund record failure")
				const callback = "local_refund:record_failure"
				require.NoError(t, db.Callback().Update().Before("gorm:update").Register(callback, func(tx *gorm.DB) {
					if tx.Statement.Schema != nil && tx.Statement.Schema.Table == "subscription_pre_consume_records" {
						_ = tx.AddError(injected)
					}
				}))
				t.Cleanup(func() { assert.NoError(t, db.Callback().Update().Remove(callback)) })
				require.ErrorIs(t, RefundSubscriptionPreConsume(records[0].RequestId), injected)
				assertLocalRefund(t, db, sub.Id, records, 400, "consumed")
			})
			t.Run("concurrent_refunds", func(t *testing.T) {
				sub, records := seedLocalRefund(t, db, 2)
				start := make(chan struct{})
				errs := make(chan error, 3)
				var wg sync.WaitGroup
				// Include a duplicate refund racing with the first request.
				for _, requestID := range []string{records[0].RequestId, records[1].RequestId, records[0].RequestId} {
					wg.Go(func() {
						<-start
						errs <- RefundSubscriptionPreConsume(requestID)
					})
				}
				close(start)
				wg.Wait()
				close(errs)
				for err := range errs {
					require.NoError(t, err)
				}
				assertLocalRefund(t, db, sub.Id, records, 100, "refunded")
			})
		})
	}
}

func seedLocalRefund(t *testing.T, db *gorm.DB, count int) (*UserSubscription, []SubscriptionPreConsumeRecord) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	previousDB := DB
	DB = db.WithContext(ctx)
	t.Cleanup(func() { DB = previousDB; cancel() })
	sub := &UserSubscription{UserId: 1, PlanId: 1, AmountTotal: 10000, AmountUsed: int64(100 + 300*count), Status: "active"}
	require.NoError(t, db.Create(sub).Error)
	t.Cleanup(func() { assert.NoError(t, db.Delete(sub).Error) })
	records := make([]SubscriptionPreConsumeRecord, count)
	for i := range count {
		records[i] = SubscriptionPreConsumeRecord{RequestId: fmt.Sprintf("local-refund-%d-%d", sub.Id, i), UserId: 1, UserSubscriptionId: sub.Id, PreConsumed: 300, Status: "consumed"}
		require.NoError(t, db.Create(&records[i]).Error)
	}
	t.Cleanup(func() { assert.NoError(t, db.Delete(&records).Error) })
	return sub, records
}

func assertLocalRefund(t *testing.T, db *gorm.DB, id int, records []SubscriptionPreConsumeRecord, used int64, status string) {
	t.Helper()
	var sub UserSubscription
	require.NoError(t, db.First(&sub, id).Error)
	assert.Equal(t, used, sub.AmountUsed)
	for _, record := range records {
		var got SubscriptionPreConsumeRecord
		require.NoError(t, db.First(&got, record.Id).Error)
		assert.Equal(t, status, got.Status)
	}
}
