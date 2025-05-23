// Copyright 2021-present StarRocks, Inc. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package com.starrocks.catalog;

import com.google.common.base.Joiner;
import com.starrocks.analysis.DescriptorTable;
import com.starrocks.common.util.TimeUtils;
import com.starrocks.planner.PaimonScanNode;
import com.starrocks.thrift.TIcebergSchema;
import com.starrocks.thrift.TIcebergSchemaField;
import com.starrocks.thrift.TPaimonTable;
import com.starrocks.thrift.TTableDescriptor;
import com.starrocks.thrift.TTableType;
import org.apache.paimon.table.DataTable;
import org.apache.paimon.types.DataField;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.stream.Collectors;

import static com.starrocks.connector.ConnectorTableId.CONNECTOR_ID_GENERATOR;

public class PaimonTable extends Table {
    private String catalogName;
    private String databaseName;
    private String tableName;
    private org.apache.paimon.table.Table paimonNativeTable;
    private List<String> partColumnNames;
    private List<String> paimonFieldNames;
    private Map<String, String> properties;

    public PaimonTable() {
        super(TableType.PAIMON);
    }

    public PaimonTable(String catalogName, String dbName, String tblName, List<Column> schema,
                       org.apache.paimon.table.Table paimonNativeTable) {
        super(CONNECTOR_ID_GENERATOR.getNextId().asInt(), tblName, TableType.PAIMON, schema);
        this.catalogName = catalogName;
        this.databaseName = dbName;
        this.tableName = tblName;
        this.paimonNativeTable = paimonNativeTable;
        this.partColumnNames = paimonNativeTable.partitionKeys();
        this.paimonFieldNames = paimonNativeTable.rowType().getFields().stream()
                .map(DataField::name)
                .collect(Collectors.toList());
    }

    @Override
    public String getCatalogName() {
        return catalogName;
    }

    @Override
    public String getCatalogDBName() {
        return databaseName;
    }

    @Override
    public String getCatalogTableName() {
        return tableName;
    }

    public org.apache.paimon.table.Table getNativeTable() {
        return paimonNativeTable;
    }

    // For refresh table only
    public void setPaimonNativeTable(org.apache.paimon.table.Table paimonNativeTable) {
        this.paimonNativeTable = paimonNativeTable;
    }

    @Override
    public String getUUID() {
        return String.join(".", catalogName, databaseName, tableName, paimonNativeTable.uuid());
    }

    @Override
    public String getTableLocation() {
        if (paimonNativeTable instanceof DataTable) {
            return ((DataTable) paimonNativeTable).location().toString();
        } else {
            return paimonNativeTable.name().toString();
        }
    }

    @Override
    public Map<String, String> getProperties() {
        if (properties == null) {
            this.properties = new HashMap<>();
            if (!paimonNativeTable.primaryKeys().isEmpty()) {
                properties.put("primary-key", String.join(",", paimonNativeTable.primaryKeys()));
            }
            this.properties.putAll(paimonNativeTable.options());
        }
        return properties;
    }

    @Override
    public List<String> getPartitionColumnNames() {
        return partColumnNames;
    }

    @Override
    public List<Column> getPartitionColumns() {
        List<Column> partitionColumns = new ArrayList<>();
        if (!partColumnNames.isEmpty()) {
            partitionColumns = partColumnNames.stream().map(this::getColumn)
                    .collect(Collectors.toList());
        }
        return partitionColumns;
    }

    public List<String> getFieldNames() {
        return paimonFieldNames;
    }

    @Override
    public boolean isUnPartitioned() {
        return partColumnNames.isEmpty();
    }

    @Override
    public boolean isSupported() {
        return true;
    }

    @Override
    public TTableDescriptor toThrift(List<DescriptorTable.ReferencedPartitionInfo> partitions) {
        TPaimonTable tPaimonTable = new TPaimonTable();
        String encodedTable = PaimonScanNode.encodeObjectToString(paimonNativeTable);
        tPaimonTable.setPaimon_native_table(encodedTable);
        tPaimonTable.setTime_zone(TimeUtils.getSessionTimeZone());

        // reuse TIcebergSchema directly for compatibility.
        TIcebergSchema tPaimonSchema = new TIcebergSchema();
        List<DataField> paimonFields = paimonNativeTable.rowType().getFields();
        List<TIcebergSchemaField> tIcebergFields = new ArrayList<>(paimonFields.size());
        for (DataField field : paimonFields) {
            tIcebergFields.add(getTIcebergSchemaField(field));
        }
        tPaimonSchema.setFields(tIcebergFields);
        tPaimonTable.setPaimon_schema(tPaimonSchema);

        TTableDescriptor tTableDescriptor = new TTableDescriptor(id, TTableType.PAIMON_TABLE,
                fullSchema.size(), 0, tableName, databaseName);
        tTableDescriptor.setPaimonTable(tPaimonTable);
        return tTableDescriptor;
    }

    private TIcebergSchemaField getTIcebergSchemaField(DataField field) {
        TIcebergSchemaField tPaimonSchemaField = new TIcebergSchemaField();
        tPaimonSchemaField.setField_id(field.id());
        tPaimonSchemaField.setName(field.name());
        return tPaimonSchemaField;
    }

    @Override
    public String getTableIdentifier() {
        String uuid = getUUID();
        return Joiner.on(":").join(name, uuid == null ? "" : uuid);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        PaimonTable that = (PaimonTable) o;
        return catalogName.equals(that.catalogName) &&
                databaseName.equals(that.databaseName) &&
                tableName.equals(that.tableName) &&
                Objects.equals(getTableIdentifier(), that.getTableIdentifier());
    }

    @Override
    public int hashCode() {
        return Objects.hash(catalogName, databaseName, tableName, getTableIdentifier());
    }
}
