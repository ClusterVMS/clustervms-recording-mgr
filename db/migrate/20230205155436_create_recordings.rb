class CreateRecordings < ActiveRecord::Migration[7.0]
  def change
    create_table :recordings do |t|
      t.string :camera
      t.string :stream
      t.string :moonfire_camera_id
      t.integer :moonfire_id
      t.integer :start_time
      t.integer :end_time
      t.integer :run_id

      t.timestamps
    end
  end
end
