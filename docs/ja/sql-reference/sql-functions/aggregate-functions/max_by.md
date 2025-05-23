---
displayed_sidebar: docs
---

# max_by

`y` の最大値に関連付けられた `x` の値を返します。

例えば、`SELECT max_by(subject, exam_result) FROM exam;` は、最高の試験スコアを持つ科目を返します。

この関数は v2.5 からサポートされています。

## Syntax

```Haskell
max_by(x,y)
```

## Parameters

- `x`: 任意のタイプの式。
- `y`: 順序付け可能なタイプの式。

## Return value

`x` と同じタイプの値を返します。

## Usage notes

- `y` はソート可能なタイプでなければなりません。`bitmap` や `hll` のようなソート不可能なタイプの `y` を使用すると、エラーが返されます。
- `y` に null 値が含まれている場合、その null 値に対応する行は無視されます。
- 複数の `x` の値が同じ最大値の `y` を持つ場合、この関数は最初に見つかった `x` の値を返します。

## Examples

1. テーブル `exam` を作成します。

    ```SQL
    CREATE TABLE exam (
        subject_id INT,
        subject STRING,
        exam_result INT
    ) DISTRIBUTED BY HASH(`subject_id`);
    ```

2. このテーブルに値を挿入し、データをクエリします。

    ```SQL
    insert into exam values
    (1,'math',90),
    (2,'english',70),
    (3,'physics',95),
    (4,'chemistry',85),
    (5,'music',95),
    (6,'biology',null);

    select * from exam order by subject_id;
    +------------+-----------+-------------+
    | subject_id | subject   | exam_result |
    +------------+-----------+-------------+
    |          1 | math      |          90 |
    |          2 | english   |          70 |
    |          3 | physics   |          95 |
    |          4 | chemistry |          85 |
    |          5 | music     |          95 |
    |          6 | biology   |        null |
    +------------+-----------+-------------+
    6 rows in set (0.03 sec)
    ```

3. 最高スコアを持つ科目を取得します。
   `physics` と `music` の 2 つの科目が同じ最高スコア `95` を持ち、最初に見つかった科目 (`physics`) が返されます。

    ```Plain
    SELECT max_by(subject, exam_result) FROM exam;
    +------------------------------+
    | max_by(subject, exam_result) |
    +------------------------------+
    | physics                      |
    +------------------------------+
    1 row in set (0.01 sec)
    ```