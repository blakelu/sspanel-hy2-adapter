package traffic

// Counter contains cumulative traffic in the client-to-server (Tx) and
// server-to-client (Rx) directions.
type Counter struct {
	Tx uint64 `json:"tx"`
	Rx uint64 `json:"rx"`
}
