$csv_path="projects_list.csv"
$private_token=""
# max is 100
$itemPerPage=100
$url="<Your-GitLab-url>/api/v4/projects?private_token=$private_token&private=true&per_page=$itemPerPage&page="

$page=1
$totalItemCount=0
$result=@()

echo "Processing..."
while (1) {
    $itemCount = 0
    curl "$url$page" | 
    ConvertFrom-Json |
    ForEach { $_ } |
    ForEach {
        # fields
        $item = "" | Select-Object name,path_with_namespace,web_url
        $item.name = $_.name
        $item.path_with_namespace = $_.path_with_namespace
        $item.web_url = $_.web_url

        $result += $item
        $itemCount += 1
    }

    echo "page $page has $itemCount item"
    $totalItemCount += $itemCount

    $page += 1
    if ($itemCount -lt $itemPerPage) { break }
}

echo "Total Item Count = $totalItemCount"

$result | Select-Object | ConvertTo-CSV -NoTypeInformation -Delimiter "`t" | Out-File -FilePath "$pwd\$csv_path"

echo "Result saved to $pwd\$csv_path"
start $pwd
